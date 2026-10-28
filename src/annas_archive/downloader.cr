require "./download_transport"
require "digest/md5"
require "digest/sha256"
require "compress/zip"
require "random/secure"
require "./output"

lib AnnaAtomicFiles
  fun linkat(olddirfd : Int32, oldpath : UInt8*, newdirfd : Int32, newpath : UInt8*, flags : Int32) : Int32
  fun unlinkat(dirfd : Int32, path : UInt8*, flags : Int32) : Int32
end

module AnnasArchive
  record DownloadPolicy, max_bytes : Int64 = 134_217_728_i64, timeout : Time::Span = 60.seconds,
    max_uncompressed_bytes : Int64 = 536_870_912_i64, max_entries : Int32 = 10_000
  record DownloadedFile, path : String, bytes : Int64, md5 : String, sha256 : String, validation : String

  class Downloader
    private class TransferFile < IO::FileDescriptor
      def read_at(offset, bytesize, &)
        raise IO::Error.new("invalid archive range") unless offset >= 0 && bytesize >= 0 && offset + bytesize <= info.size
        before = pos
        seek(offset)
        yield IO::Sized.new(self, bytesize)
      ensure
        seek(before) if before
      end
    end

    @cooldowns = {} of String => Time::Span
    @cooldown_lock = Mutex.new

    def initialize(@transport : StreamTransport = NativeHTTPTransport.new, @policy : DownloadPolicy = DownloadPolicy.new,
                   @origin : String? = nil, @challenge_retries : Bool = true,
                   @clock : Proc(Time::Span) = -> { Time.instant - CLOCK_ORIGIN })
      raise Error.new("invalid_input") unless @policy.max_bytes.in?(1_i64..2_147_483_648_i64) && @policy.max_uncompressed_bytes.in?(1_i64..2_147_483_648_i64) && @policy.max_entries.in?(1..65_535)
      if origin = @origin
        uri = PublicHTTPS.uri(origin)
        raise Error.new("invalid_input") unless uri.path.in?({"", "/"}) && !uri.query
        @origin = origin.rstrip('/')
      end
      TransferContext.new(@policy.timeout)
    end

    def download(resolution : Resolution, destination : String, expected_md5 : String, format : String? = nil,
                 cancelled : Proc(Bool) = -> { false }, progress : Proc(Int64, Nil)? = nil) : DownloadedFile
      raise Error.new("download_wait_required", resolution.wait_seconds) if resolution.wait_seconds
      download(resolution.url || raise(Error.new("unsupported_resolution")), destination, expected_md5, format, cancelled, progress)
    end

    def download(url : String, destination : String?, expected_md5 : String, format : String? = nil,
                 cancelled : Proc(Bool) = -> { false }, progress : Proc(Int64, Nil)? = nil,
                 shared_context : TransferContext? = nil, landing : Proc(String, String, String)? = nil,
                 output_directory : String = ".", prepare_parents : Bool = false) : DownloadedFile
      host = PublicHTTPS.uri(url).host.not_nil!.downcase
      check_cooldown!(host)
      raise Error.new("invalid_input") unless expected_md5.matches?(/\A[a-fA-F0-9]{32}\z/) && (!format || format.in?(%w[epub zip cbz docx pdf rar cbr]))
      published = false
      context = shared_context || TransferContext.new(@policy.timeout, cancelled)
      context.check!
      if prepare_parents || destination.nil?
        prepared = PreparedOutputDirectory.new(destination ? File.dirname(destination) : output_directory, context)
        parent = prepared.path
        directory = prepared.directory
        dir_fd = directory.fd
      else
        parent = File.realpath(File.dirname(destination.not_nil!))
        dir_fd = LibC.open(parent, LibC::O_RDONLY | LibC::O_NOFOLLOW | LibC::O_CLOEXEC)
        raise Error.new("download_output_invalid") if dir_fd < 0
        IO::FileDescriptor.set_blocking(dir_fd, true)
        directory = IO::FileDescriptor.new(dir_fd)
      end
      name = destination.try { |path| File.basename(path) }
      raise Error.new("download_output_invalid") if name && (name.empty? || name.in?({".", ".."}) || name.includes?('\0'))
      info = directory.info
      raise Error.new("download_output_invalid") unless info.directory? && info.owner_id == LibC.getuid.to_s && info.permissions.value & 0o022 == 0
      target = name.try { |value| File.join(parent, value) }
      raise Error.new("download_file_exists") if target && (File.exists?(target) || File.symlink?(target))
      partial = ".anna-#{Random::Secure.hex(16)}.part"
      fd = AnnaAtomicFiles.openat(dir_fd, partial, LibC::O_RDWR | LibC::O_CREAT | LibC::O_EXCL | LibC::O_NOFOLLOW | LibC::O_CLOEXEC, 0o600_u32)
      raise Error.new("download_output_invalid") if fd < 0
      IO::FileDescriptor.set_blocking(fd, true)
      output = TransferFile.new(fd)
      md5 = Digest::MD5.new
      sha = Digest::SHA256.new
      total = 0_i64
      transfer_url = url
      retried = false
      loop do
        begin
          next_url = nil.as(String?)
          host = PublicHTTPS.uri(transfer_url).host.not_nil!.downcase
          check_cooldown!(host)
          @transport.open(transfer_url, context) do |response|
            inspect_challenge!(response.body, context) if response.status.in?({401, 403, 503})
            status!(response, host)
            encoding = response.headers["Content-Encoding"]?.to_s.downcase
            raise Error.new("download_invalid_response") unless encoding.empty? || encoding == "identity"
            declared = response.headers["Content-Length"]?
            raise Error.new("download_invalid_response") if declared && (!declared.matches?(/\A[0-9]+\z/) || !declared.to_i64?)
            length = declared.try(&.to_i64)
            raise Error.new("download_size_limit") if length && length > @policy.max_bytes
            type = response.headers["Content-Type"]?.to_s.downcase
            if type.includes?("html")
              if handler = landing
                next_url = handler.call(read_page(response.body, context), response.url || transfer_url)
                next
              end
              inspect_challenge!(response.body, context)
              raise Error.new("download_invalid_response")
            end
            raise Error.new("download_invalid_response") if type.includes?("json") || type.includes?("xml")
            prefix = Bytes.new(Math.min(512_i64, @policy.max_bytes + 1).to_i)
            count = response.body.read_greedy(prefix)
            raise Error.new("download_empty") if count == 0
            sniff = String.new(prefix[0, count]).scrub.lstrip("\uFEFF \t\r\n").downcase
            if handler = landing
              if ["<!doctype", "<html", "<head", "<script", "<body", "<title", "<form"].any? { |start| sniff.starts_with?(start) }
                next_url = handler.call(read_page(response.body, context, String.new(prefix[0, count])), response.url || transfer_url)
                next
              end
            end
            inspect_challenge!(response.body, context, String.new(prefix[0, count])) if ["<!doctype", "<html", "<head", "<script", "<body", "<title", "<form"].any? { |start| sniff.starts_with?(start) }
            raise Error.new("download_invalid_response") if ["<!doctype", "<html", "<head", "<script", "<body", "<title", "<form", "<?xml", "{\"", "{\n"].any? { |prefix| sniff.starts_with?(prefix) }
            unless name
              name = OutputNaming.filename(response.headers, response.url || transfer_url)
              target = File.join(parent, name.not_nil!)
              raise Error.new("download_file_exists") if File.exists?(target.not_nil!) || File.symlink?(target.not_nil!)
            end
            buffer = prefix
            loop do
              context.check!
              total += count
              raise Error.new("download_size_limit") if total > @policy.max_bytes
              output.write(buffer[0, count]); md5.update(buffer[0, count]); sha.update(buffer[0, count])
              progress.try(&.call(total))
              buffer = Bytes.new(65_536) if buffer.size < 65_536
              count = response.body.read(buffer[0, Math.min(buffer.size.to_i64, @policy.max_bytes - total + 1).to_i])
              break if count == 0
            end
            raise Error.new("download_truncated") if length && total != length
            nil
          end
          if target_url = next_url
            PublicHTTPS.uri(target_url)
            transfer_url = target_url
            next
          end
          break
        rescue ex : Error
          remember_cooldown!(host, ex.retry_after || 60) if ex.code == "rate_limited"
          raise ex unless ex.code == "browser_verification_required" && total == 0 && !retried && @challenge_retries && slow_retry?(transfer_url)
          retried = true
          context.check!
          transfer_url = transfer_url.sub("/slow_download/", "/slow%5Fdownload/")
        end
      end
      context.check!
      checksum = md5.final.hexstring
      raise Error.new("download_md5_mismatch") unless checksum == expected_md5.downcase
      output.flush
      validation = validate_file(output, format, context)
      output.fsync
      context.check!
      raise Error.new("download_output_changed") unless File.info(parent, follow_symlinks: false).same_file?(directory.info)
      prepared.try(&.check!)
      if AnnaAtomicFiles.linkat(dir_fd, partial, dir_fd, name.not_nil!, 0) != 0
        raise Error.new(Errno.value == Errno::EEXIST ? "download_file_exists" : "download_io_error")
      end
      published = true
      sync_directory(directory)
      raise Error.new("download_output_changed") unless File.info(parent, follow_symlinks: false).same_file?(directory.info)
      prepared.try(&.check!)
      DownloadedFile.new(target.not_nil!, total, checksum, sha.final.hexstring, validation)
    rescue ex : Error
      raise Error.new("download_publication_uncertain") if published
      raise ex
    rescue ex : IO::TimeoutError
      raise Error.new("download_publication_uncertain") if published
      context.try(&.check!)
      raise Error.new("download_timeout")
    rescue
      raise Error.new("download_publication_uncertain") if published
      context.try(&.check!)
      raise Error.new("download_io_error")
    ensure
      begin
        output.try(&.close)
      rescue IO::Error
      end
      if directory && partial
        AnnaAtomicFiles.unlinkat(directory.fd, partial, 0)
        directory.fsync rescue nil
      end
      directory.try(&.close)
    end

    private def slow_retry?(url : String) : Bool
      return false unless origin = @origin
      uri = URI.parse(url)
      base = URI.parse(origin)
      uri.scheme == base.scheme && uri.host == base.host && uri.port == base.port &&
        uri.path.matches?(/\A\/slow_download\/[a-f0-9]{32}\/\d+\/\d+\/?\z/)
    end

    private def read_page(body : IO, context : TransferContext, prefix : String = "") : String
      output = IO::Memory.new
      output << prefix
      buffer = Bytes.new(16_384)
      loop do
        context.check!
        count = body.read(buffer)
        break if count == 0
        raise Error.new("page_too_large") if output.size + count > MAX_PAGE_BYTES
        output.write(buffer[0, count])
      end
      output.to_s
    end

    private def inspect_challenge!(body : IO, context : TransferContext, prefix : String = "") : Nil
      output = IO::Memory.new
      output << prefix
      buffer = Bytes.new(16_384)
      loop do
        context.check!
        count = body.read(buffer)
        break if count == 0
        raise Error.new("page_too_large") if output.size + count > MAX_PAGE_BYTES
        output.write(buffer[0, count])
      end
      begin
        Parser.document(output.to_s) unless output.empty?
      rescue ex : Error
        raise ex if ex.code == "browser_verification_required" || ex.code == "page_too_large"
      end
    end

    protected def sync_directory(directory : IO::FileDescriptor) : Nil
      directory.fsync
    end

    private def check_cooldown!(host : String) : Nil
      @cooldown_lock.synchronize do
        @cooldowns.reject! { |_, until_at| until_at <= @clock.call }
        if until_at = @cooldowns[host]?
          raise Error.new("rate_limited", Math.max((until_at - @clock.call).total_seconds.ceil.to_i, 1))
        end
      end
    end

    private def remember_cooldown!(host : String, delay : Int32) : Nil
      @cooldown_lock.synchronize do
        @cooldowns.reject! { |_, until_at| until_at <= @clock.call }
        raise Error.new("download_cooldown_capacity") if @cooldowns.size >= 32 && !@cooldowns.has_key?(host)
        @cooldowns[host] = @clock.call + Math.max(delay, 1).seconds
      end
    end

    private def status!(response : StreamResponse, host : String) : Nil
      status = response.status
      if status == 429
        delay = RetryDelay.seconds(response.headers["Retry-After"]?) || 60
        remember_cooldown!(host, delay)
        raise Error.new("rate_limited", delay)
      end
      raise Error.new("authentication_required") if status == 401
      raise Error.new("access_denied") if status == 403
      raise Error.new("download_http_error") unless status == 200
    end

    private def preflight_zip!(io : TransferFile) : Nil
      # Bound central-directory allocation before the stdlib constructs entries.
      size = io.info.size
      length = Math.min(size, 65_557_i64).to_i
      io.seek(size - length)
      tail = io.read_string(length)
      index = tail.bytesize - 4
      at = nil.as(Int32?)
      bytes = tail.to_slice
      while index >= 0
        if bytes[index] == 80 && bytes[index + 1] == 75 && bytes[index + 2] == 5 && bytes[index + 3] == 6
          at = index
          break
        end
        index -= 1
      end
      at = at || raise Error.new("download_invalid_file")
      raise Error.new("download_invalid_file") if at + 22 > tail.bytesize
      fields = IO::Memory.new(tail.byte_slice(at + 4, 18))
      disk = fields.read_bytes(UInt16, IO::ByteFormat::LittleEndian)
      directory_disk = fields.read_bytes(UInt16, IO::ByteFormat::LittleEndian)
      disk_entries = fields.read_bytes(UInt16, IO::ByteFormat::LittleEndian)
      entries = fields.read_bytes(UInt16, IO::ByteFormat::LittleEndian)
      directory_size = fields.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
      directory_offset = fields.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
      comment = fields.read_bytes(UInt16, IO::ByteFormat::LittleEndian)
      raise Error.new("download_invalid_file") unless disk == 0 && directory_disk == 0 && disk_entries == entries && entries > 0 && entries < 65_535 && at + 22 + comment == tail.bytesize && directory_size.to_i64 + directory_offset <= size - length + at
      raise Error.new("download_expansion_limit") if entries > @policy.max_entries
    end

    private def validate_file(io : TransferFile, format : String?, context : TransferContext) : String
      return "hash_only" unless format
      io.seek(0)
      signature = io.read_string(4)
      if format.in?(%w[epub zip cbz docx])
        raise Error.new("download_invalid_file") unless signature == "PK\u0003\u0004"
        preflight_zip!(io)
        context.check!
        io.seek(0)
        zip = Compress::Zip::File.new(io)
        raise Error.new("download_invalid_file") if zip.entries.empty? || zip.entries.size > @policy.max_entries
        total = 0_i64
        buffer = Bytes.new(65_536)
        epub_type = ""
        zip.entries.each do |entry|
          context.check!
          raise Error.new("download_expansion_limit") if total + entry.uncompressed_size > @policy.max_uncompressed_bytes
          entry.open do |source|
            loop do
              context.check!
              count = source.read(buffer)
              break if count == 0
              total += count
              raise Error.new("download_expansion_limit") if total > @policy.max_uncompressed_bytes
              if entry.filename == "mimetype"
                raise Error.new("download_invalid_file") if epub_type.bytesize + count > 256
                epub_type += String.new(buffer[0, count])
              end
            end
          end
        end
        raise Error.new("download_invalid_file") if format == "epub" && (epub_type.strip != "application/epub+zip" || !zip.entries.any? { |entry| entry.filename == "META-INF/container.xml" })
        "zip_crc"
      elsif format == "pdf"
        io.seek(0)
        prefix = Bytes.new(8)
        count = io.read_greedy(prefix)
        raise Error.new("download_invalid_file") unless String.new(prefix[0, count]).matches?(/\A%PDF-[12]\.[0-9]/)
        "signature"
      else
        io.seek(0)
        prefix = Bytes.new(8)
        count = io.read_greedy(prefix)
        magic = String.new(prefix[0, count])
        raise Error.new("download_invalid_file") unless magic.starts_with?("Rar!\u001a\u0007\u0000") || magic == "Rar!\u001a\u0007\u0001\u0000"
        "signature"
      end
    rescue ex : Error
      raise ex
    rescue
      raise Error.new("download_invalid_file")
    end
  end
end
