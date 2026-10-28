require "uri"

lib AnnaAtomicFiles
  fun openat(dirfd : LibC::Int, path : LibC::Char*, flags : LibC::Int, ...) : LibC::Int
  fun mkdirat(dirfd : LibC::Int, path : LibC::Char*, mode : LibC::ModeT) : LibC::Int
end

module AnnasArchive
  # Filename metadata is only a suggestion, never a path. Decode once before
  # removing separators; cap by UTF-8 bytes without splitting a character.
  module OutputNaming
    extend self

    def safe_filename(value : String) : String
      raise Error.new("download_invalid_response") if value.bytesize > 8192
      decoded = URI.decode(value).scrub.gsub('\\', '/').split('/').last.to_s
      name = decoded.gsub(/[\x00-\x1f\x7f-\x9f<>:"|?*]/, "_").strip(" .")
      name = "_" + name if name.split('.').first?.to_s.rstrip(" .").matches?(/\A(?:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])\z/i)
      result = String.build do |io|
        bytes = 0
        name.each_char do |char|
          break if bytes + char.bytesize > 180
          io << char
          bytes += char.bytesize
        end
      end.rstrip(" .")
      result.empty? ? "download.bin" : result
    end

    def filename(headers : HTTP::Headers, url : String) : String
      disposition = headers["Content-Disposition"]?.to_s
      raise Error.new("download_invalid_response") if disposition.bytesize > 8192
      if encoded = disposition.match(/(?:\A|;)\s*filename\*\s*=\s*UTF-8'[^']*'([^;]*)/i)
        return safe_filename(encoded[1].strip)
      end
      if ordinary = disposition.match(/(?:\A|;)\s*filename\s*=\s*(?:"([^"]*)"|([^;]*))/i)
        return safe_filename(ordinary[1]? || ordinary[2].strip)
      end
      safe_filename(URI.parse(url).path.split('/').last.to_s)
    end
  end

  # Automatic preparation uses no-follow descriptor-relative traversal from /.
  # Existing ancestry must not be shared-writable and must be root/caller-owned.
  # New descendants may be created only beneath caller-owned directories.
  private class PreparedOutputDirectory
    getter path : String
    getter directory : IO::FileDescriptor
    @chain : Array({String, File::Info})

    def initialize(value : String, context : TransferContext)
      raise Error.new("download_output_invalid") unless value.bytesize.in?(1..4096) && !value.includes?('\0')
      @path = File.expand_path(value)
      segments = @path.split('/').reject(&.empty?)
      raise Error.new("download_output_invalid") if segments.size > 128
      @chain = [] of {String, File::Info}
      @directory = open_tree(segments, context)
      begin
        check!
      rescue ex
        @directory.close
        raise ex
      end
    end

    private def open_tree(segments : Array(String), context : TransferContext) : IO::FileDescriptor
      fd = LibC.open("/", LibC::O_RDONLY | LibC::O_NONBLOCK | LibC::O_NOFOLLOW | LibC::O_CLOEXEC)
      raise Error.new("download_output_invalid") if fd < 0
      current = IO::FileDescriptor.new(fd)
      prefix = "/"
      validate!(current.info)
      @chain << {prefix, current.info}
      segments.each do |segment|
        context.check!
        child = AnnaAtomicFiles.openat(current.fd, segment, LibC::O_RDONLY | LibC::O_NONBLOCK | LibC::O_NOFOLLOW | LibC::O_CLOEXEC)
        if child < 0 && Errno.value == Errno::ENOENT
          info = current.info
          raise Error.new("download_output_invalid") unless info.owner_id == LibC.getuid.to_s && info.permissions.value & 0o022 == 0
          if AnnaAtomicFiles.mkdirat(current.fd, segment, 0o700_u32) != 0
            raise Error.new("download_output_invalid") unless Errno.value == Errno::EEXIST
          end
          child = AnnaAtomicFiles.openat(current.fd, segment, LibC::O_RDONLY | LibC::O_NONBLOCK | LibC::O_NOFOLLOW | LibC::O_CLOEXEC)
        end
        raise Error.new("download_output_invalid") if child < 0
        next_directory = IO::FileDescriptor.new(child)
        current.close
        current = next_directory
        validate!(current.info)
        prefix = File.join(prefix, segment)
        @chain << {prefix, current.info}
      end
      info = current.info
      raise Error.new("download_output_invalid") unless info.owner_id == LibC.getuid.to_s
      current
    rescue ex
      current.try(&.close)
      raise ex if ex.is_a?(Error)
      raise Error.new("download_output_invalid")
    end

    private def validate!(info : File::Info) : Nil
      raise Error.new("download_output_invalid") unless info.directory? && info.owner_id.in?({"0", LibC.getuid.to_s}) && info.permissions.value & 0o022 == 0
    end

    def check! : Nil
      @chain.each do |path, expected|
        actual = File.info(path, follow_symlinks: false)
        raise Error.new("download_output_changed") unless actual.same_file?(expected)
        validate!(actual)
      end
      raise Error.new("download_output_changed") unless File.info(@path, follow_symlinks: false).same_file?(@directory.info)
    rescue ex : Error
      raise ex
    rescue
      raise Error.new("download_output_changed")
    end
  end
end
