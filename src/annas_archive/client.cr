require "xml"
require "uri"
require "set"
require "http/params"

# Bounded metadata client with one-shot challenge compatibility retries.
# The caller supplies its HTTP policy; no scripts or external runtime execute.
module AnnasArchive
  VERSION          = "0.3.0"
  MAX_PAGE_BYTES   = 1_048_576
  MAX_RESULTS      =        50
  MAX_RECORD_LINKS =       128
  CLOCK_ORIGIN     = Time.instant

  class Error < Exception
    getter code : String
    getter retry_after : Int32?

    def initialize(@code : String, @retry_after : Int32? = nil)
      super(@code)
    end
  end

  record Response, status : Int32, body : String, retry_after : Int32? = nil
  record Entry, md5 : String, title : String, language : String?, format : String?, summary : String,
    author : String? = nil, publisher : String? = nil, size : String? = nil, cover_url : String? = nil, url : String? = nil
  record Link, url : String, kind : String, label : String = ""
  record Detail, entry : Entry, links : Array(Link), description : String = ""
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

    def md5_path(value : String, origin : String? = nil) : String?
      # Reconstruct record URLs from identifiers; never follow an arbitrary href.
      uri = URI.parse(value)
      return nil if uri.user || uri.password
      if uri.host || uri.scheme
        return nil unless origin
        base = URI.parse(origin)
        return nil unless uri.scheme == base.scheme && uri.host == base.host && uri.port == base.port
      end
      uri.path.match(/\A\/md5\/([a-fA-F0-9]{32})\/?\z/).try(&.[1].downcase)
    rescue URI::Error
      nil
    end

    def summary_text(node : XML::Node?) : String
      return "" unless node
      clean = document(node.to_s)
      clean.xpath_nodes("//a | //script | //style").each(&.unlink)
      text(clean).rstrip(" ·")
    end

    def icon_text(node : XML::Node, icon : String) : String
      text(node.xpath_node(".//*[contains(@class,'#{icon}')]/ancestor::a[1]"))
    end

    def metadata_url(value : String?, origin : String?) : String?
      return nil unless value && !value.empty?
      uri = URI.parse(origin || "").resolve(value)
      return nil if uri.user || uri.password || uri.fragment || uri.scheme && uri.scheme != "https"
      uri.to_s
    rescue URI::Error
      nil
    end

    def entry(md5 : String, title : String, summary : String) : Entry
      raise Error.new("malformed_response") unless title.bytesize.in?(1..1024) && summary.bytesize <= 4096
      language = summary.match(/\[([a-z]{2,3}(?:[-_][a-z0-9]+)?)\]/i).try(&.[1].downcase)
      format = summary.split(/[,·]/).map(&.strip.downcase).find { |part| part.matches?(/\A(?:cbz|cbr|zip|rar|pdf|epub|mobi|azw3?|djvu?|txt|rtf|docx?|html|fb2)\z/) }
      size = summary.match(/\b\d+(?:[.,]\d+)?\s*[KMGT]?i?B\b/i).try(&.[0])
      Entry.new(md5, title, language, format, summary, size: size)
    end

    private def search_anchors(doc : XML::Node) : Array(XML::Node)
      # Expand deferred comment cards at their document position, so a local
      # result limit preserves the same ranking/order as the reference parser.
      anchors = [] of XML::Node
      stack = [] of {XML::Node, Bool, Int32}
      stack << {doc, false, 0}
      until stack.empty?
        node, deferred, depth = stack.pop
        raise Error.new("result_limit") if depth > 128
        if node.comment?
          if deferred
            fragment = document(node.content)
            stack << {fragment, false, depth + 1}
          end
          next
        end
        anchors << node if node.element? && node.name == "a" && node["href"]?
        inside = deferred || node["class"]?.try { |value| value.split.includes?("js-scroll-hidden") } || false
        node.children.to_a.reverse_each { |child| stack << {child, inside, depth + 1} }
      end
      anchors
    end

    def search(body : String, origin : String? = nil, limit : Int32? = nil) : Array(Entry)
      raise Error.new("invalid_input") if limit && !limit.in?(1..MAX_RESULTS)
      doc = document(body)
      found = {} of String => Entry
      search_anchors(doc).each do |anchor|
        md5 = md5_path(anchor["href"], origin) || next
        next if found.has_key?(md5)
        title = anchor.xpath_node(".//h3") || anchor.xpath_node(".//*[#{has_class("font-bold")}]")
        if title
          next if anchor.xpath_node(".//*[#{has_class("js-aarecord-list-fallback-cover")}]")
          title_text = text(title)
          summary = text(anchor.xpath_node(".//*[#{has_class("text-gray-500")}]"))
          author_node = anchor.xpath_node(".//*[#{has_class("italic")}]")
          publisher_node = title.xpath_node("following-sibling::div[1]")
          author = text(author_node)
          publisher = publisher_node == author_node ? "" : text(publisher_node)
          cover = metadata_url(anchor.xpath_node(".//img[@src]").try(&.["src"]), origin)
        elsif anchor["class"]?.try(&.split.includes?("js-vim-focus"))
          details = anchor.parent.try(&.parent) || next
          title_text = text(anchor)
          summary = summary_text(details.xpath_node(".//*[#{has_class("text-gray-800")}]"))
          author = icon_text(details, "mdi--user-edit")
          publisher = icon_text(details, "mdi--company")
          cover = metadata_url(details.parent.try(&.xpath_node(".//img[@src]")).try(&.["src"]), origin)
        else
          next
        end
        next if title_text.empty?
        found[md5] = entry(md5, title_text, summary).copy_with(author: author, publisher: publisher, cover_url: cover,
          url: origin.try { |base| URI.parse(base).resolve("/md5/#{md5}").to_s })
        return found.values if limit && found.size >= limit
        raise Error.new("result_limit") if found.size > MAX_RESULTS
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
        container = title.parent.not_nil!
        summary = summary_text(container.xpath_node(".//*[#{has_class("text-gray-800")}]"))
        author = icon_text(container, "mdi--user-edit")
        publisher = icon_text(container, "mdi--company")
        cover = metadata_url(container.xpath_node(".//img[@src]").try(&.["src"]), origin)
        description = text(container.xpath_node(".//*[#{has_class("js-md5-top-box-description")}]"))
      else
        title = doc.xpath_node("//*[#{has_class("text-3xl")}]") || raise Error.new("unrecognized_page")
        summary = text(title.xpath_node("preceding-sibling::div[1]"))
        publisher_node = title.xpath_node("following-sibling::div[1]")
        publisher = text(publisher_node)
        author = text(publisher_node.try(&.xpath_node("following-sibling::div[1]")))
        cover = metadata_url(doc.xpath_node("//*[#{has_class("js-cover-background")}]/../img[@src]").try(&.["src"]), origin)
        description = text(doc.xpath_node("//*[#{has_class("js-md5-top-box-description")}]"))
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
        label = text(anchor)
        links << Link.new(url, kind, label.empty? ? uri.host.not_nil! : label)
        raise Error.new("result_limit") if links.size > MAX_RECORD_LINKS
      end
      Detail.new(entry(md5, text(title), summary).copy_with(author: author, publisher: publisher, cover_url: cover,
        url: URI.parse(origin).resolve("/md5/#{md5}").to_s), links, description)
    rescue URI::Error
      raise Error.new("malformed_response")
    end

    # Parse only an ordinary accessible landing page. The caller schedules a
    # countdown and validates each returned URL through its transport policy.
    # Parsing alone never performs requests or changes URL encoding.
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
    # Recognized challenges alone allow one same-origin compatibility retry.
    def initialize(@origin : String, @fetch : Proc(String, Response), @delay_seconds : Int32 = 30,
                   @clock : Proc(Time::Span) = -> { Time.instant - CLOCK_ORIGIN }, @challenge_retries : Bool = true)
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

    def search(query : String, language : String? = nil, format : String? = nil,
               languages : Array(String) = [] of String, formats : Array(String) = [] of String,
               content : Array(String) = [] of String, page : Int32? = nil, sort : String? = nil, limit : Int32? = nil) : Array(Entry)
      raise Error.new("invalid_input") unless query.bytesize.in?(1..512) && !query.strip.empty? && !query.matches?(/[\x00-\x1f\x7f]/)
      language_filters = (language ? [language] : [] of String) + languages
      format_filters = (format ? [format] : [] of String) + formats
      raise Error.new("invalid_input") unless language_filters.size <= 20 && format_filters.size <= 20 && content.size <= 20
      raise Error.new("invalid_input") unless language_filters.all? { |value| value.matches?(/\A[a-z]{2,3}(?:-[a-z0-9]+)?\z/) }
      raise Error.new("invalid_input") unless format_filters.all? { |value| value.matches?(/\A(?:cbz|cbr|zip|rar|pdf|epub|mobi|azw3?|djvu?|txt|rtf|docx?|html|fb2)\z/) }
      raise Error.new("invalid_input") unless content.all? { |value| value.matches?(/\A[a-z][a-z0-9_]{0,63}\z/) }
      raise Error.new("invalid_input") if page && page < 1
      raise Error.new("invalid_input") if limit && !limit.in?(1..MAX_RESULTS)
      raise Error.new("invalid_input") if sort && !sort.in?(%w[relevance newest oldest largest smallest newest_added oldest_added])
      params = HTTP::Params.new
      params.add("q", query)
      params.add("display", "")
      language_filters.each { |value| params.add("lang", value) }
      format_filters.each { |value| params.add("ext", value) }
      content.each { |value| params.add("content", value) }
      params.add("sort", sort) if sort
      params.add("page", page.to_s) if page
      Parser.search(page("/search?#{params}"), @origin, limit)
    end

    def detail(md5 : String) : Detail
      raise Error.new("invalid_input") unless md5.matches?(/\A[a-fA-F0-9]{32}\z/)
      Parser.detail(page("/md5/#{md5.downcase}"), md5.downcase, @origin)
    end

    def resolve(url : String) : Resolution
      uri = parse_origin(url)
      base = URI.parse(@origin)
      raise Error.new("invalid_input") unless url.bytesize <= 4096 && uri.scheme == base.scheme && uri.host == base.host && uri.port == base.port && !uri.user && !uri.password && !uri.fragment && uri.path.matches?(/\A\/slow_download\/[a-f0-9]{32}\/\d+\/\d+\/?\z/)
      Parser.resolve(page(uri.request_target, slow: true), url)
    end

    private def page(path : String, slow : Bool = false) : String
      @lock.synchronize do
        now = @clock.call
        raise Error.new("rate_limited", (@next_request - now).total_seconds.ceil.to_i.clamp(1, 3600)) if now < @next_request
        @next_request = now + @delay_seconds.seconds
        begin
          begin
            request_page(@origin + path)
          rescue ex : Error
            raise ex unless @challenge_retries && ex.code == "browser_verification_required"
            retry_path = slow ? path.sub("/slow_download/", "/slow%5Fdownload/") : path + (path.includes?('?') ? "&" : "?") + "check=%31"
            @next_request = @clock.call + @delay_seconds.seconds
            request_page(@origin + retry_path)
          end
        rescue ex : Error
          if ex.code == "rate_limited" && (delay = ex.retry_after)
            @next_request = @clock.call + Math.max(delay, 1).seconds
          end
          raise ex
        end
      end
    end

    private def request_page(url : String) : String
      response = fetch(url)
      if response.status == 429
        raise Error.new("rate_limited", Math.max(response.retry_after || @delay_seconds, 1))
      end
      Parser.document(response.body) unless response.body.strip.empty?
      raise Error.new("authentication_required") if response.status == 401
      raise Error.new("access_denied") if response.status == 403
      raise Error.new("unavailable") unless response.status == 200
      response.body
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
