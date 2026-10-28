require "http/cookie"

module AnnasArchive
  # Conservative RFC6265 subset: domain cookies are narrowed to the exact host.
  # Memory-only, bounded to 32 cookies of at most 1024 bytes; no disk import.
  class CookieSession
    private record Stored, host : String, path : String, cookie : HTTP::Cookie, expires : Time?
    @cookies = [] of Stored
    @lock = Mutex.new

    def initialize(@clock : Proc(Time) = -> { Time.utc })
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
