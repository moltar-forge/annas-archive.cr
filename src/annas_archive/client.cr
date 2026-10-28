require "xml"
require "uri"
require "set"
require "http/params"

# An extractable, metadata-only HTML client. No credentials, process execution,
# challenge retries or file downloads. The caller supplies its HTTP policy.
module AnnasArchive
  VERSION        = "0.1.0"
  MAX_PAGE_BYTES = 1_048_576
  MAX_RESULTS    =        50
  CLOCK_ORIGIN   = Time.instant

  class Error < Exception
    getter code : String
    getter retry_after : Int32?

    def initialize(@code : String, @retry_after : Int32? = nil)
      super(@code)
    end
  end

  record Response, status : Int32, body : String, retry_after : Int32? = nil
  record Entry, md5 : String, title : String, language : String?, format : String?, summary : String
  record Link, url : String, kind : String
  record Detail, entry : Entry, links : Array(Link)
  record Resolution, url : String? = nil, wait_seconds : Int32? = nil

  module Parser
    extend self

    def has_class(name : String) : String
      "contains(concat(' ',normalize-space(@class),' '),' #{name} ')"
    end

    # Ignore hidden ranking text and controls when reading a card. HTML comments
    # are parsed only inside the site's explicit deferred-result containers.
    def text(node : XML::Node?) : String
      return "" unless node
      return "" if node.comment? || node.name.in?({"script", "style"}) || node["class"]?.try { |value| value.split.any? { |klass| klass.in?({"hidden", "select-none"}) } }
      return node.content if node.text?
      node.children.map { |child| text(child) }.join(" ").gsub(/\s+/, " ").strip
    end

    def document(body : String) : XML::Node
      raise Error.new("page_too_large") if body.bytesize > MAX_PAGE_BYTES
      raise Error.new("malformed_response") unless body.valid_encoding?
      doc = XML.parse_html(body, options: XML::HTMLParserOptions::RECOVER | XML::HTMLParserOptions::NONET | XML::HTMLParserOptions::NOERROR | XML::HTMLParserOptions::NOWARNING)
      title = text(doc.xpath_node("//title")).downcase
      if title.matches?(/ddos-guard|just a moment|attention required/) ||
         doc.xpath_node("//*[@id='challenge-form' or @id='cf-challenge-running']") ||
         doc.xpath_node("//script[contains(@src,'ddos-guard') or contains(@src,'challenge-platform')]")
        raise Error.new("browser_verification_required")
      end
      raise Error.new("unrecognized_page") if body.matches?(/this domain may be for sale|forsale\.min\.js/i)
      doc
    rescue XML::Error
      raise Error.new("malformed_response")
    end

    def md5_path(value : String) : String?
      # Metadata links are relative record identifiers, never retrieval authority.
      value.match(/\A\/md5\/([a-fA-F0-9]{32})\/?\z/).try(&.[1].downcase)
    end

    def entry(md5 : String, title : String, summary : String) : Entry
      raise Error.new("malformed_response") unless title.bytesize.in?(1..1024) && summary.bytesize <= 4096
      language = summary.match(/\[([a-z]{2,3}(?:[-_][a-z0-9]+)?)\]/i).try(&.[1].downcase)
      format = summary.split(/[,·]/).map(&.strip.downcase).find { |part| part.matches?(/\A(?:cbz|cbr|zip|rar|pdf|epub|mobi|azw3?|djvu?|txt|fb2)\z/) }
      Entry.new(md5, title, language, format, summary)
    end

    def search(body : String) : Array(Entry)
      doc = document(body)
      fragments = [doc]
      doc.xpath_nodes("//*[#{has_class("js-scroll-hidden")}]//comment()").each do |comment|
        fragments << document(comment.content)
      end
      found = {} of String => Entry
      fragments.each do |fragment|
        fragment.xpath_nodes("//a[@href]").each do |anchor|
          md5 = md5_path(anchor["href"]) || next
          next if found.has_key?(md5)
          title = anchor.xpath_node(".//h3") || anchor.xpath_node(".//*[#{has_class("font-bold")}]")
          if title
            next if anchor.xpath_node(".//*[#{has_class("js-aarecord-list-fallback-cover")}]")
            title_text = text(title)
            summary = text(anchor.xpath_node(".//*[#{has_class("text-gray-500")}]"))
          elsif anchor["class"]?.try(&.split.includes?("js-vim-focus"))
            details = anchor.parent.try(&.parent) || next
            title_text = text(anchor)
            summary_node = details.xpath_node(".//*[#{has_class("text-gray-800")}]")
            # Strip controls from a copy so title/other card links remain intact.
            if summary_node
              clean = document(summary_node.to_s)
              clean.xpath_nodes("//a").each(&.unlink)
              summary = text(clean)
            else
              summary = ""
            end
          else
            next
          end
          next if title_text.empty?
          found[md5] = entry(md5, title_text, summary)
          raise Error.new("result_limit") if found.size > MAX_RESULTS
        end
      end
      if found.empty? && !text(doc).matches?(/no files found|no results(?: found)?|没有找到|未找到|找不到/i)
        raise Error.new("unrecognized_page")
      end
      found.values
    end

    def detail(body : String, md5 : String, origin : String) : Detail
      raise Error.new("invalid_input") unless md5.matches?(/\A[a-f0-9]{32}\z/)
      doc = document(body)
      title = doc.xpath_node("//div[#{has_class("text-2xl")} and #{has_class("font-semibold")}]")
      if title
        summary = title.parent.try { |parent| text(parent.xpath_node(".//*[#{has_class("text-gray-800")}]")) } || ""
      else
        title = doc.xpath_node("//*[#{has_class("text-3xl")}]") || raise Error.new("unrecognized_page")
        summary = text(title.xpath_node("preceding-sibling::div[1]"))
      end
      links = [] of Link
      seen = Set(String).new
      doc.xpath_nodes("//a[#{has_class("js-download-link")} and @href]").each do |anchor|
        uri = URI.parse(origin).resolve(anchor["href"])
        next unless uri.scheme == "https" && uri.host && !uri.user && !uri.password && !uri.fragment
        url = uri.to_s
        next if seen.includes?(url)
        seen << url
        kind = uri.path.starts_with?("/fast_download/") ? "member" : uri.path.starts_with?("/slow_download/") ? "browser" : "external"
        links << Link.new(url, kind)
        raise Error.new("result_limit") if links.size > 20
      end
      Detail.new(entry(md5, text(title), summary), links)
    rescue URI::Error
      raise Error.new("malformed_response")
    end

    # Parse only an ordinary accessible landing page. The caller schedules a
    # countdown and validates each returned URL through its transport policy.
    # Never change a URL to evade a challenge or infer a hidden download route.
    def resolve(body : String, page_url : String) : Resolution
      doc = document(body)
      raise Error.new("authentication_required") if doc.xpath_node("//input[translate(@type,'PASSWORD','password')='password']")
      if countdown = doc.xpath_node("//*[#{has_class("js-partner-countdown")}]")
        delay = text(countdown)
        raise Error.new("unrecognized_page") unless delay.matches?(/\A\d{1,6}\z/)
        return Resolution.new(wait_seconds: delay.to_i)
      end
      candidates = doc.xpath_nodes("//a[(@download or @id='download') and @href]").to_a
      if candidates.empty?
        candidates = doc.xpath_nodes("//a[@href]").select do |anchor|
          text(anchor).downcase.lstrip("📚").strip.in?({"get", "download now", "download file", "立即下载"})
        end
      end
      candidates.each do |anchor|
        uri = URI.parse(page_url).resolve(anchor["href"])
        next unless uri.scheme == "https" && uri.host && !uri.user && !uri.password && !uri.fragment
        next if uri.to_s == page_url
        return Resolution.new(url: uri.to_s)
      end
      raise Error.new("unsupported_resolution")
    rescue URI::Error
      raise Error.new("malformed_response")
    end
  end

  class Client
    getter origin : String

    # The transport must enforce exact-host/DNS/redirect/size/time policies.
    # This library neither loads cookies nor alters blocked URLs to retry them.
    def initialize(@origin : String, @fetch : Proc(String, Response), @delay_seconds : Int32 = 30,
                   @clock : Proc(Time::Span) = -> { Time.instant - CLOCK_ORIGIN })
      uri = parse_origin(@origin)
      raise Error.new("invalid_input") unless uri.scheme == "https" && uri.host && !uri.user && !uri.password && !uri.port && uri.path.in?({"", "/"}) && !uri.query && !uri.fragment && @delay_seconds.in?(1..3600)
      @origin = @origin.rstrip('/')
      @next_request = Time::Span.zero
      @lock = Mutex.new
    end

    private def parse_origin(origin : String) : URI
      URI.parse(origin)
    rescue URI::Error
      raise Error.new("invalid_input")
    end

    def search(query : String, language : String? = nil, format : String? = nil) : Array(Entry)
      raise Error.new("invalid_input") unless query.bytesize.in?(1..512) && !query.strip.empty? && !query.matches?(/[\x00-\x1f\x7f]/)
      raise Error.new("invalid_input") if language && !language.matches?(/\A[a-z]{2,3}(?:-[a-z0-9]+)?\z/)
      raise Error.new("invalid_input") if format && !format.in?({"cbz", "cbr", "zip", "rar"})
      params = HTTP::Params.new
      params.add("q", query)
      params.add("display", "")
      params.add("lang", language) if language
      params.add("ext", format) if format
      Parser.search(page("/search?#{params}"))
    end

    def detail(md5 : String) : Detail
      raise Error.new("invalid_input") unless md5.matches?(/\A[a-fA-F0-9]{32}\z/)
      Parser.detail(page("/md5/#{md5.downcase}"), md5.downcase, @origin)
    end

    def resolve(url : String) : Resolution
      uri = parse_origin(url)
      base = URI.parse(@origin)
      raise Error.new("invalid_input") unless url.bytesize <= 4096 && uri.scheme == base.scheme && uri.host == base.host && uri.port == base.port && !uri.user && !uri.password && !uri.fragment && uri.path.matches?(/\A\/slow_download\/[a-f0-9]{32}\/\d+\/\d+\/?\z/)
      Parser.resolve(page(uri.request_target), url)
    end

    private def page(path : String) : String
      @lock.synchronize do
        now = @clock.call
        raise Error.new("rate_limited", (@next_request - now).total_seconds.ceil.to_i.clamp(1, 3600)) if now < @next_request
        @next_request = now + @delay_seconds.seconds
        begin
          response = fetch(@origin + path)
        rescue ex : Error
          if ex.code == "rate_limited" && (delay = ex.retry_after)
            @next_request = @clock.call + Math.max(delay, 1).seconds
          end
          raise ex
        end
        if response.status == 429
          delay = Math.max(response.retry_after || @delay_seconds, 1)
          @next_request = @clock.call + delay.seconds
          raise Error.new("rate_limited", delay)
        end
        # Recognize 200/403/503 challenges without retry; empty error responses
        # retain their HTTP classification rather than becoming parser failures.
        Parser.document(response.body) unless response.body.strip.empty?
        raise Error.new("authentication_required") if response.status == 401
        raise Error.new("access_denied") if response.status == 403
        raise Error.new("unavailable") unless response.status == 200
        response.body
      end
    end

    private def fetch(url : String) : Response
      @fetch.call(url)
    rescue ex : Error
      raise ex
    rescue
      # Exceptions from a transport can contain endpoints or signed locators.
      raise Error.new("network_error")
    end
  end
end
