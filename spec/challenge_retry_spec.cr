require "spec"
require "file_utils"
require "json"
require "base64"
require "../src/annas_archive"

private class RetryResolver < AnnasArchive::PublicResolver
  def resolve(host : String, context : AnnasArchive::TransferContext) : Array(String)
    context.check!
    ["8.8.8.8"]
  end
end

# This seam uses real native URL/DNS/redirect policy, cookie retention and request
# header construction. Only socket/TLS exchange is replaced; no live requests.
private class RetryNativeTransport < AnnasArchive::NativeHTTPTransport
  getter requests = [] of {String, HTTP::Headers}
  property failure : AnnasArchive::Error? = nil
  property after_response : Proc(Nil)? = nil

  def initialize(@responses : Array({Int32, HTTP::Headers, String}))
    super(RetryResolver.new)
  end

  protected def proxy_configured? : Bool
    false
  end

  protected def exchange(uri : URI, address : String, context : AnnasArchive::TransferContext, headers : HTTP::Headers, &block : AnnasArchive::StreamResponse -> Nil) : Nil
    context.check!
    index = @requests.size
    @requests << {uri.to_s, headers}
    raise failure.not_nil! if failure && index > 0
    status, response_headers, body = @responses[Math.min(index, @responses.size - 1)]
    @after_response.try(&.call)
    yield AnnasArchive::StreamResponse.new(status, response_headers, IO::Memory.new(body))
  end
end

private def challenge_response(status = 403)
  {status, HTTP::Headers{"Content-Type" => "text/html", "Set-Cookie" => "session=test; Path=/; Secure"}, "<title>Just a moment</title>"}
end

private def retry_ok(body = "<p>No results found</p>")
  {200, HTTP::Headers.new, body}
end

private def retry_directory(&)
  directory = File.tempname("anna-retry")
  Dir.mkdir(directory, mode: 0o700)
  yield directory, File.join(directory, "book.epub")
ensure
  FileUtils.rm_rf(directory) if directory
end

private def slow_url
  "https://catalog.example.invalid/slow_download/#{"1" * 32}/0/0?key=a%2Bb&x=1&x=2&empty=&z=%ff+%20"
end

describe "native challenge compatibility" do
  it "completes search detail resolve and verified EPUB download after session retries" do
    data = JSON.parse(File.read("#{__DIR__}/differential/download_cases.json"))
    archive = String.new(Base64.decode(data["archive_b64"].as_s))
    md5 = Digest::MD5.hexdigest(archive)
    origin = "https://catalog.example.invalid"
    landing = "#{origin}/slow_download/#{md5}/0/0?token=a%2Bb&x=1&x=2&empty=&z=%ff+%20"
    file_route = "#{origin}/slow_download/#{md5}/1/1?signature=%2f%2F+&a=1&a=2"
    transport = RetryNativeTransport.new([
      challenge_response, retry_ok(%(<a href='/md5/#{md5}'><h3>Fixture</h3></a>)),
      challenge_response(503), retry_ok(%(<div class='text-3xl'>Fixture</div><a class='js-download-link' href='#{landing.gsub("&", "&amp;")}'>Slow</a>)),
      challenge_response, retry_ok(%(<a download href='#{file_route.gsub("&", "&amp;")}'>Get</a>)),
      challenge_response(200), {200, HTTP::Headers{"Content-Type" => "application/epub+zip", "Content-Length" => archive.bytesize.to_s}, archive},
    ])
    now = Time::Span.zero
    client = AnnasArchive::Client.new(origin, ->(url : String) { transport.page(url) }, clock: -> { now })
    entry = client.search("中文 & Austen", formats: ["epub", "pdf"]).first
    now += 30.seconds
    detail = client.detail(entry.md5)
    now += 30.seconds
    resolution = client.resolve(detail.links.first.url)
    retry_directory do |dir, path|
      result = AnnasArchive::Downloader.new(transport, origin: origin).download(resolution, path, entry.md5, "epub")
      result.md5.should eq md5
      result.sha256.should eq Digest::SHA256.hexdigest(archive)
      result.validation.should eq "zip_crc"
      File.read(path).should eq archive
      Dir.children(dir).should eq ["book.epub"]
    end
    urls = transport.requests.map(&.[0])
    urls.size.should eq 8
    urls[1].should eq urls[0] + "&check=%31"
    urls[3].should eq urls[2] + "?check=%31"
    urls[4].should eq landing
    urls[5].should eq landing.sub("/slow_download/", "/slow%5Fdownload/")
    urls[7].should eq file_route.sub("/slow_download/", "/slow%5Fdownload/")
    params = HTTP::Params.parse(URI.parse(urls[1]).query.not_nil!)
    params.fetch_all("ext").should eq ["epub", "pdf"]
    params["q"].should eq "中文 & Austen"
    transport.requests[0][1]["Cookie"]?.should be_nil
    transport.requests[1..].each { |_, headers| headers["Cookie"].should eq "session=test" }
  end

  it "bounds page and download challenge retries to one and keeps errors closed" do
    transport = RetryNativeTransport.new([challenge_response])
    client = AnnasArchive::Client.new("https://catalog.example.invalid", ->(url : String) { transport.page(url) })
    error = expect_raises(AnnasArchive::Error, "browser_verification_required") { client.search("x") }
    error.message.should eq error.code
    transport.requests.size.should eq 2
    transport = RetryNativeTransport.new([challenge_response])
    retry_directory do |dir, path|
      downloader = AnnasArchive::Downloader.new(transport, origin: "https://catalog.example.invalid")
      expect_raises(AnnasArchive::Error, "browser_verification_required") { downloader.download(slow_url, path, "1" * 32) }
      transport.requests.size.should eq 2
      Dir.children(dir).should be_empty
    end
  end

  it "never retries plain HTTP failures, unknown pages or transport errors" do
    {401 => "authentication_required", 403 => "access_denied", 429 => "rate_limited", 503 => "unavailable", 200 => "unrecognized_page"}.each do |status, code|
      transport = RetryNativeTransport.new([{status, HTTP::Headers.new, "<html>ordinary error</html>"}])
      client = AnnasArchive::Client.new("https://catalog.example.invalid", ->(url : String) { transport.page(url) })
      expect_raises(AnnasArchive::Error, code) { client.search("x") }
      transport.requests.size.should eq 1
      retry_directory do |dir, path|
        transport = RetryNativeTransport.new([{status, HTTP::Headers.new, "<html>ordinary error</html>"}])
        downloader = AnnasArchive::Downloader.new(transport, origin: "https://catalog.example.invalid")
        expect_raises(AnnasArchive::Error) { downloader.download(slow_url, path, "1" * 32) }
        transport.requests.size.should eq 1
        Dir.children(dir).should be_empty
      end
    end
    calls = 0
    client = AnnasArchive::Client.new("https://catalog.example.invalid", ->(_url : String) { calls += 1; raise "secret"; AnnasArchive::Response.new(200, "") })
    expect_raises(Exception, "secret") { client.search("x") }
    calls.should eq 1
  end

  it "does not grant rewriting to external, encoded, malformed or unconfigured routes" do
    [slow_url.sub("catalog.example.invalid", "other.example.invalid"), slow_url.sub("/slow_download/", "/slow%5Fdownload/"), slow_url.sub("/0/0?", "/0/no?"), slow_url.sub("/slow_download/", "/prefix/slow_download/")].each do |url|
      transport = RetryNativeTransport.new([challenge_response])
      retry_directory do |dir, path|
        downloader = AnnasArchive::Downloader.new(transport, origin: "https://catalog.example.invalid")
        expect_raises(AnnasArchive::Error, "browser_verification_required") { downloader.download(url, path, "1" * 32) }
        transport.requests.size.should eq 1
        Dir.children(dir).should be_empty
      end
    end
    [nil, "https://catalog.example.invalid"].each do |origin|
      transport = RetryNativeTransport.new([challenge_response])
      retry_directory do |dir, path|
        downloader = AnnasArchive::Downloader.new(transport, origin: origin, challenge_retries: origin.nil?)
        expect_raises(AnnasArchive::Error, "browser_verification_required") { downloader.download(slow_url, path, "1" * 32) }
        transport.requests.size.should eq 1
      end
    end
  end

  it "retains second-response cooldowns for metadata and downloads" do
    [false, true].each do |typed|
      transport = RetryNativeTransport.new([challenge_response, {429, HTTP::Headers{"Retry-After" => "120"}, ""}])
      transport.failure = AnnasArchive::Error.new("rate_limited", 120) if typed
      client = AnnasArchive::Client.new("https://catalog.example.invalid", ->(url : String) { transport.page(url) }, clock: -> { Time::Span.zero })
      expect_raises(AnnasArchive::Error, "rate_limited") { client.search("x") }.retry_after.should eq 120
      expect_raises(AnnasArchive::Error, "rate_limited") { client.search("x") }.retry_after.should eq 120
      transport.requests.size.should eq 2
      transport = RetryNativeTransport.new([challenge_response, {429, HTTP::Headers{"Retry-After" => "120"}, ""}])
      transport.failure = AnnasArchive::Error.new("rate_limited", 120) if typed
      retry_directory do |dir, path|
        downloader = AnnasArchive::Downloader.new(transport, origin: "https://catalog.example.invalid")
        expect_raises(AnnasArchive::Error, "rate_limited") { downloader.download(slow_url, path, "1" * 32) }.retry_after.should eq 120
        expect_raises(AnnasArchive::Error, "rate_limited") { downloader.download(slow_url, path, "1" * 32) }
        transport.requests.size.should eq 2
        Dir.children(dir).should be_empty
      end
    end
  end

  it "bounds challenge bodies and honors cancellation before the second exchange" do
    transport = RetryNativeTransport.new([{403, HTTP::Headers.new, "x" * (AnnasArchive::MAX_PAGE_BYTES + 1)}])
    retry_directory do |dir, path|
      downloader = AnnasArchive::Downloader.new(transport, origin: "https://catalog.example.invalid")
      expect_raises(AnnasArchive::Error, "page_too_large") { downloader.download(slow_url, path, "1" * 32) }
      transport.requests.size.should eq 1
      Dir.children(dir).should be_empty
    end
    cancelled = false
    transport = RetryNativeTransport.new([challenge_response])
    transport.after_response = -> { cancelled = true; nil }
    retry_directory do |dir, path|
      downloader = AnnasArchive::Downloader.new(transport, origin: "https://catalog.example.invalid")
      expect_raises(AnnasArchive::Error, "download_cancelled") { downloader.download(slow_url, path, "1" * 32, cancelled: -> { cancelled }) }
      transport.requests.size.should eq 1
      Dir.children(dir).should be_empty
    end
  end
end

describe "native cookie transport seam" do
  it "retains redirect cookies but never forwards a session to a different host" do
    transport = RetryNativeTransport.new([
      {302, HTTP::Headers{"Location" => "/next", "Set-Cookie" => "session=redirect; Path=/; Secure"}, ""},
      retry_ok,
      retry_ok,
    ])
    transport.page("https://catalog.example.invalid/start")
    transport.page("https://other.example.invalid/end")
    transport.requests[0][1]["Cookie"]?.should be_nil
    transport.requests[1][1]["Cookie"].should eq "session=redirect"
    transport.requests[2][1]["Cookie"]?.should be_nil
    transport.requests[1][1]["Accept-Encoding"].should eq "identity"
    transport.requests[1][1]["Host"].should eq "catalog.example.invalid"
    transport.requests[1][1]["User-Agent"].should eq "annas-archive.cr/#{AnnasArchive::VERSION}"
  end

  it "does not widen redirect policy when a challenge sets a cookie" do
    transport = RetryNativeTransport.new([
      {302, HTTP::Headers{"Location" => "https://other.example.invalid/file", "Set-Cookie" => "session=test; Path=/"}, ""},
    ])
    expect_raises(AnnasArchive::Error, "download_redirect_blocked") { transport.page("https://catalog.example.invalid/start") }
    transport.requests.size.should eq 1
  end
end

describe "retry failure boundaries" do
  it "never retries 429 even with challenge markers" do
    transport = RetryNativeTransport.new([challenge_response(429)])
    client = AnnasArchive::Client.new("https://catalog.example.invalid", ->(url : String) { transport.page(url) })
    expect_raises(AnnasArchive::Error, "rate_limited") { client.search("x") }
    transport.requests.size.should eq 1
    transport = RetryNativeTransport.new([challenge_response(429)])
    retry_directory do |dir, path|
      downloader = AnnasArchive::Downloader.new(transport, origin: "https://catalog.example.invalid")
      expect_raises(AnnasArchive::Error, "rate_limited") { downloader.download(slow_url, path, "1" * 32) }
      transport.requests.size.should eq 1
      Dir.children(dir).should be_empty
    end
  end

  it "keeps the charged interval when the second exchange fails" do
    transport = RetryNativeTransport.new([challenge_response])
    transport.failure = AnnasArchive::Error.new("download_network_error")
    client = AnnasArchive::Client.new("https://catalog.example.invalid", ->(url : String) { transport.page(url) }, clock: -> { Time::Span.zero })
    expect_raises(AnnasArchive::Error, "download_network_error") { client.search("x") }
    expect_raises(AnnasArchive::Error, "rate_limited") { client.search("x") }
    transport.requests.size.should eq 2
    transport = RetryNativeTransport.new([challenge_response])
    transport.failure = AnnasArchive::Error.new("download_network_error")
    retry_directory do |dir, path|
      downloader = AnnasArchive::Downloader.new(transport, origin: "https://catalog.example.invalid")
      expect_raises(AnnasArchive::Error, "download_network_error") { downloader.download(slow_url, path, "1" * 32) }
      transport.requests.size.should eq 2
      Dir.children(dir).should be_empty
    end
  end
end
