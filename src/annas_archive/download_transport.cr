require "http/client"
require "socket"
require "openssl"

module AnnasArchive
  class TransferContext
    def initialize(timeout : Time::Span = 60.seconds, @cancelled : Proc(Bool) = -> { false })
      raise Error.new("invalid_input") unless timeout > Time::Span.zero && timeout <= 5.minutes
      @deadline = Time.instant + timeout
    end

    def check! : Nil
      raise Error.new("download_cancelled") if @cancelled.call
      raise Error.new("download_timeout") if Time.instant >= @deadline
    end

    def remaining : Time::Span
      check!
      @deadline - Time.instant
    end
  end

  module RetryDelay
    extend self

    def seconds(value : String?) : Int32?
      return nil unless value
      if value.matches?(/\A[0-9]+\z/)
        number = value.to_i64? || raise Error.new("download_retry_after_unsupported")
        raise Error.new("download_retry_after_unsupported") if number > Int32::MAX
        Math.max(number.to_i, 1)
      elsif date = HTTP.parse_time(value)
        seconds = (date - Time.utc).total_seconds.ceil
        raise Error.new("download_retry_after_unsupported") if seconds > Int32::MAX
        Math.max(seconds.to_i, 1)
      else
        nil
      end
    end
  end

  record StreamResponse, status : Int32, headers : HTTP::Headers, body : IO

  abstract class StreamTransport
    abstract def open(url : String, context : TransferContext, &block : StreamResponse -> Nil) : Nil

    # Metadata uses the identical native transport/policy but a separate bound.
    def page(url : String, context = TransferContext.new(30.seconds)) : Response
      value = nil.as(Response?)
      open(url, context) do |response|
        output = IO::Memory.new
        buffer = Bytes.new(16_384)
        loop do
          context.check!
          count = response.body.read(buffer)
          break if count == 0
          raise Error.new("page_too_large") if output.size + count > MAX_PAGE_BYTES
          output.write(buffer[0, count])
        end
        delay = RetryDelay.seconds(response.headers["Retry-After"]?)
        value = Response.new(response.status, output.to_s, delay)
        nil
      end
      value.not_nil!
    end
  end

  module PublicHTTPS
    extend self

    def uri(url : String) : URI
      raise Error.new("download_url_blocked") unless url.bytesize.in?(1..4096) && url.each_byte.all? { |c| c > 32 && c < 127 } && !url.includes?('\\')
      parsed = URI.parse(url)
      host = parsed.host.to_s.downcase
      raise Error.new("download_url_blocked") unless parsed.scheme == "https" && (!parsed.port || parsed.port == 443) && !parsed.user && !parsed.password && !parsed.fragment && host.bytesize <= 253 && host.matches?(/\A(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{1,62}\z/) && !Socket::IPAddress.valid?(host)
      parsed
    rescue URI::Error
      raise Error.new("download_url_blocked")
    end

    def public_address?(value : String) : Bool
      return false if value.includes?('%') || !Socket::IPAddress.valid?(value)
      address = Socket::IPAddress.new(value, 443).address
      if address.includes?(':')
        words = address.split(':')
        first = words.first.to_i?(16) || return false
        second = words[1]?.try(&.to_i?(16)) || 0
        return false unless first.in?(0x2000..0x3fff)
        return false if first == 0x2002 || first == 0x2001 && (second < 0x0200 || second == 0x0db8)
        return false if first == 0x3fff && second < 0x1000
        return true
      end
      parts = address.split('.').map(&.to_u32)
      number = (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3]
      ranges = [{0_u32, 8}, {10_u32 << 24, 8}, {100_u32 << 24 | 64_u32 << 16, 10}, {127_u32 << 24, 8},
                {169_u32 << 24 | 254_u32 << 16, 16}, {172_u32 << 24 | 16_u32 << 16, 12},
                {192_u32 << 24, 24}, {192_u32 << 24 | 2_u32 << 8, 24}, {192_u32 << 24 | 88_u32 << 16 | 99_u32 << 8, 24}, {192_u32 << 24 | 168_u32 << 16, 16},
                {198_u32 << 24 | 18_u32 << 16, 15}, {198_u32 << 24 | 51_u32 << 16 | 100_u32 << 8, 24}, {203_u32 << 24 | 113_u32 << 8, 24}, {224_u32 << 24, 3}]
      !ranges.any? { |network, bits| mask = UInt32::MAX << (32 - bits); number & mask == network & mask }
    rescue
      false
    end
  end

  class PublicResolver
    # libc DNS is not cancellable on every Crystal platform. A single bounded
    # outstanding worker prevents callers exceeding their deadline or creating
    # unbounded resolver threads. A stuck worker makes later calls fail busy.
    private class LookupResult
      property value : Array(String)? = nil
      getter ready = Atomic(Bool).new(false)
    end

    @@busy = Atomic(Bool).new(false)

    def resolve(host : String, context : TransferContext) : Array(String)
      context.check!
      raise Error.new("download_resolver_busy") unless @@busy.compare_and_set(false, true)[1]
      result = LookupResult.new
      begin
        Thread.new do
          begin
            result.value = lookup(host)
          rescue
            result.value = nil
          ensure
            @@busy.set(false)
            result.ready.set(true)
          end
        end
      rescue
        @@busy.set(false)
        raise Error.new("download_dns_failed")
      end
      loop do
        context.check!
        return result.value || raise(Error.new("download_dns_failed")) if result.ready.get
        sleep Math.min(context.remaining, 1.millisecond)
      end
    end

    protected def lookup(host : String) : Array(String)
      # This synchronous C call runs exclusively on the bounded resolver thread;
      # no Crystal fiber/channel operations cross the native thread boundary.
      hints = LibC::Addrinfo.new
      hints.ai_family = Socket::Family::UNSPEC.to_i32
      hints.ai_socktype = Socket::Type::STREAM.to_i32
      hints.ai_protocol = Socket::Protocol::TCP.to_i32
      output = Pointer(Pointer(LibC::Addrinfo)).malloc(1, Pointer(LibC::Addrinfo).null)
      code = LibC.getaddrinfo(host, "443", pointerof(hints), output)
      raise Error.new("download_dns_failed") unless code == 0
      addresses = [] of String
      cursor = output.value
      until cursor.null?
        raise Error.new("download_dns_failed") if addresses.size >= 64
        item = cursor.value
        if item.ai_family.in?({Socket::Family::INET.value, Socket::Family::INET6.value})
          addresses << Socket::IPAddress.from(item.ai_addr, item.ai_addrlen).address
        end
        cursor = item.ai_next
      end
      addresses.uniq
    ensure
      LibC.freeaddrinfo(output.value) if output && !output.value.null?
    end
  end

  class NativeHTTPTransport < StreamTransport
    def initialize(@resolver : PublicResolver = PublicResolver.new, @max_redirects : Int32 = 3)
      raise Error.new("invalid_input") unless @max_redirects.in?(0..5)
    end

    def open(url : String, context : TransferContext, &block : StreamResponse -> Nil) : Nil
      initial = PublicHTTPS.uri(url)
      # Never silently route around an embedding environment's proxy policy.
      # Authorized proxy environments must inject a policy-preserving transport.
      raise Error.new("download_proxy_transport_required") if proxy_configured?
      current = initial
      (@max_redirects + 1).times do |hop|
        context.check!
        raise Error.new("download_redirect_blocked") unless current.host.try(&.downcase) == initial.host.try(&.downcase)
        addresses(current.host.not_nil!, context)
        address = addresses(current.host.not_nil!, context).first
        redirect : URI? = nil
        perform(current, address, context) do |response|
          if response.status.in?({301, 302, 303, 307, 308})
            raise Error.new("download_redirect_limit") if hop == @max_redirects
            locations = response.headers.get?("Location")
            raise Error.new("download_redirect_blocked") unless locations && locations.size == 1
            redirect = PublicHTTPS.uri(current.resolve(locations.first).to_s)
            raise Error.new("download_redirect_blocked") unless redirect.not_nil!.host.try(&.downcase) == initial.host.try(&.downcase)
          else
            yield response
          end
          nil
        end
        context.check!
        addresses(current.host.not_nil!, context)
        return unless redirect
        current = redirect.not_nil!
      end
    rescue ex : Error
      raise ex
    rescue
      context.check!
      raise Error.new("download_network_error")
    end

    protected def proxy_configured? : Bool
      %w[HTTP_PROXY HTTPS_PROXY ALL_PROXY http_proxy https_proxy all_proxy].any? { |name| ENV[name]?.try { |v| !v.strip.empty? } || false }
    end

    private def addresses(host : String, context : TransferContext) : Array(String)
      answers = @resolver.resolve(host, context).uniq
      raise Error.new("download_dns_failed") if answers.empty? || answers.size > 64
      raise Error.new("download_address_blocked") unless answers.all? { |address| PublicHTTPS.public_address?(address) }
      answers
    end

    protected def connect_socket(socket : Socket, address : Socket::IPAddress, context : TransferContext) : Nil
      socket.connect(address, timeout: context.remaining)
    end

    protected def perform(uri : URI, address : String, context : TransferContext, &block : StreamResponse -> Nil) : Nil
      ip = Socket::IPAddress.new(address, 443)
      socket = Socket.tcp(ip.family)
      stop = Channel(Nil).new(1)
      spawn do
        loop do
          select
          when stop.receive
            break
          when timeout(25.milliseconds)
            begin
              context.check!
            rescue Error
              socket.close rescue nil
              break
            end
          end
        end
      end
      begin
        socket.read_timeout = context.remaining
        socket.write_timeout = context.remaining
        connect_socket(socket, ip, context)
        tls = OpenSSL::SSL::Socket::Client.new(socket, context: OpenSSL::SSL::Context::Client.new, sync_close: true, hostname: uri.host.not_nil!)
        client = HTTP::Client.new(tls, uri.host.not_nil!, 443)
        headers = HTTP::Headers{"Host" => uri.host.not_nil!, "Accept-Encoding" => "identity", "User-Agent" => "annas-archive.cr/#{VERSION}"}
        client.get(uri.request_target, headers) do |response|
          begin
            yield StreamResponse.new(response.status_code, response.headers, response.body_io)
          ensure
            # Avoid draining an untrusted redirect/error body during cleanup.
            client.close
          end
        end
      ensure
        stop.send(nil)
        client.try(&.close)
        socket.close rescue nil
      end
    end
  end
end
