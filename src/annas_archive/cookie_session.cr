require "http/cookie"

module AnnasArchive
  # Conservative RFC6265 subset: domain cookies are narrowed to the exact host.
  # Bounded to 32 cookies of at most 1024 bytes; explicit scoped import only.
  class CookieSession
    private record Stored, host : String, path : String, cookie : HTTP::Cookie, expires : Time?
    @cookies = [] of Stored
    @lock = Mutex.new

    def initialize(@clock : Proc(Time) = -> { Time.utc })
    end

    MAX_IMPORT_BYTES = 65_536
    MAX_IMPORT_LINES =    256

    # No profile discovery or ambient file access. A malformed import never
    # partially mutates the session. Domain exports narrow to this exact host.
    def import_netscape(input : IO, origin : String) : Nil
      output = IO::Memory.new
      buffer = Bytes.new(4096)
      loop do
        count = input.read(buffer)
        break if count == 0
        raise Error.new("cookie_import_too_large") if output.size + count > MAX_IMPORT_BYTES
        output.write(buffer[0, count])
      end
      import_netscape(output.to_s, origin)
    rescue ex : Error
      raise ex
    rescue
      raise Error.new("cookie_import_unreadable")
    end

    def import_netscape_file(path : String, origin : String) : Nil
      File.open(path) { |input| import_netscape(input, origin) }
    rescue ex : Error
      raise ex
    rescue
      raise Error.new("cookie_import_unreadable")
    end

    def import_netscape(input : String, origin : String) : Nil
      raise Error.new("cookie_import_too_large") if input.bytesize > MAX_IMPORT_BYTES || input.count('\n') + 1 > MAX_IMPORT_LINES
      raise Error.new("cookie_import_invalid") unless input.valid_encoding? && input.each_byte.all? { |c| c.in?(32..126) || c.in?({9_u8, 10_u8, 13_u8}) }
      uri = PublicHTTPS.uri(origin)
      raise Error.new("cookie_import_invalid") unless uri.path.in?({"", "/"}) && !uri.query
      host = uri.host.not_nil!.downcase
      staged = [] of Stored
      input.each_line do |line|
        raise Error.new("cookie_import_too_large") if line.bytesize > 2048
        line = line.rstrip('\r')
        http_only = line.starts_with?("#HttpOnly_")
        line = line.byte_slice(10) if http_only
        next if line.empty? || line.starts_with?('#')
        raise Error.new("cookie_import_invalid") unless line.each_byte.all? { |c| c == 9 || c.in?(32..126) }
        fields = line.split('\t')
        raise Error.new("cookie_import_invalid") unless fields.size == 7
        domain, subdomains, path, secure_text, expiry, name, value = fields
        raise Error.new("cookie_import_invalid") unless subdomains.in?({"TRUE", "FALSE"}) && secure_text.in?({"TRUE", "FALSE"}) && expiry.matches?(/\A\d{1,18}\z/)
        domain = domain.downcase
        plain = domain.lchop('.')
        raise Error.new("cookie_import_invalid") unless plain.matches?(/\A[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?\z/) && !plain.includes?("..") && (!domain.starts_with?('.') || subdomains == "TRUE")
        secure = secure_text == "TRUE"
        raise Error.new("cookie_import_invalid") unless path.starts_with?('/') && path.each_byte.all? { |c| c.in?(33..126) && c != 59 }
        raise Error.new("cookie_import_invalid") unless name.matches?(/\A[!#$%&'*+.^_`|~0-9a-zA-Z-]+\z/)
        raise Error.new("cookie_import_invalid") unless value.each_byte.all? { |c| c == 33 || c.in?(35..43) || c.in?(45..58) || c.in?(60..91) || c.in?(93..126) }
        raise Error.new("cookie_import_invalid") if name.starts_with?("__Secure-") && !secure
        raise Error.new("cookie_import_invalid") if name.starts_with?("__Host-") && (!secure || path != "/" || subdomains == "TRUE" || domain.starts_with?('.'))
        raise Error.new("cookie_import_too_large") if host.bytesize + path.bytesize + name.bytesize + value.bytesize + 64 > 1024
        seconds = expiry.to_i64
        expires = seconds == 0 ? nil : Time.unix(seconds)
        next unless host == plain || subdomains == "TRUE" && host.ends_with?(".#{plain}")
        cookie = HTTP::Cookie.new(name, value, path: path, secure: secure, http_only: http_only)
        staged << Stored.new(host, path, cookie, expires)
      end
      @lock.synchronize do
        merged = @cookies.reject { |item| item.expires.try { |t| t <= @clock.call } || false }
        staged.each do |item|
          merged.reject! { |old| old.host == item.host && old.path == item.path && old.cookie.name == item.cookie.name }
          next if item.expires.try { |t| t <= @clock.call }
          raise Error.new("cookie_import_capacity") if merged.size >= 32
          merged << item
        end
        @cookies = merged
      end
    rescue ex : Error
      raise ex if ex.code.starts_with?("cookie_import_")
      raise Error.new("cookie_import_invalid")
    rescue
      raise Error.new("cookie_import_invalid")
    end

    def retain(uri : URI, headers : HTTP::Headers) : Nil
      return unless uri.scheme == "https"
      @lock.synchronize do
        @cookies.reject! { |item| item.expires.try { |t| t <= @clock.call } || false }
        (headers.get?("Set-Cookie") || [] of String).first(32).each do |raw|
          next if raw.bytesize > 1024
          begin
            parts = raw.split(';').map(&.strip)
            pair = parts.shift.split('=', 2)
            next unless pair.size == 2
            attrs = {} of String => String
            parts.each do |part|
              key, _, value = part.partition('=')
              attrs[key.downcase] = value
            end
            host = uri.host.to_s.downcase
            domain = attrs["domain"]?
            next if domain && domain.lstrip('.').downcase != host
            secure = attrs.has_key?("secure")
            path = attrs["path"]?
            path = nil unless path.try(&.starts_with?("/"))
            default_path = uri.path.rpartition('/')[0]
            path ||= default_path.empty? ? "/" : default_path
            next if pair[0].starts_with?("__Secure-") && !secure
            next if pair[0].starts_with?("__Host-") && (!secure || domain || attrs["path"]? != "/")
            value = pair[1]
            if value.starts_with?('"') && value.ends_with?('"') && value.bytesize >= 2
              value = value.byte_slice(1, value.bytesize - 2)
            end
            cookie = HTTP::Cookie.new(pair[0], value, path: path, secure: secure)
            expires = attrs["expires"]?.try { |v| HTTP.parse_time(v) }
            age_value = attrs["max-age"]?
            if age = age_value.try { |v| v.matches?(/\A-?[0-9]+\z/) ? v.to_i64? : nil }
              expires = age <= 0 ? @clock.call : @clock.call + Math.min(age, 31_536_000_i64).seconds
            end
            @cookies.reject! { |item| item.host == host && item.path == path && item.cookie.name == cookie.name }
            next if expires && expires <= @clock.call
            next if @cookies.size >= 32
            @cookies << Stored.new(host, path, cookie, expires)
          rescue ArgumentError | IO::Error | OverflowError
          end
        end
      end
    end

    def header(uri : URI) : String?
      @lock.synchronize do
        @cookies.reject! { |item| item.expires.try { |t| t <= @clock.call } || false }
        selected = @cookies.select do |item|
          path = uri.path.empty? ? "/" : uri.path
          item.host == uri.host.to_s.downcase && (!item.cookie.secure || uri.scheme == "https") &&
            (path == item.path || path.starts_with?(item.path.ends_with?("/") ? item.path : item.path + "/"))
        end.sort_by { |item| -item.path.bytesize }
        value = selected.map(&.cookie.to_cookie_header).join("; ")
        value.empty? ? nil : value
      end
    end
  end
end
