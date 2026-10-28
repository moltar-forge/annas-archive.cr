require "spec"
require "file_utils"
require "../src/annas_archive"

private def export_cookie(name = "session", value = "synthetic", domain = "catalog.example.invalid", subdomains = false, path = "/", secure = true, expiry = "0")
  [domain, subdomains ? "TRUE" : "FALSE", path, secure ? "TRUE" : "FALSE", expiry, name, value].join('\t')
end

private def cookie_origin
  "https://catalog.example.invalid"
end

private class UnreadableCookieIO < IO
  def read(slice : Bytes) : Int32
    raise IO::Error.new("synthetic private path/value")
  end

  def write(slice : Bytes) : Nil
    raise IO::Error.new("no")
  end
end

describe "explicit Netscape import" do
  it "narrows domain exports to one authorized host and honors path Secure HttpOnly and session0" do
    jar = AnnasArchive::CookieSession.new
    text = "# Netscape HTTP Cookie File\n" + [
      "#HttpOnly_" + export_cookie,
      export_cookie("parent", "yes", ".example.invalid", true, "/dir", false),
      export_cookie("foreign", "no", "other.example.invalid"),
      export_cookie("suffix", "no", ".ample.invalid", true),
      export_cookie("child", "no", "sub.catalog.example.invalid"),
    ].join('\n')
    jar.import_netscape(IO::Memory.new(text), cookie_origin)
    jar.header(URI.parse(cookie_origin + "/dir/book")).should eq "parent=yes; session=synthetic"
    jar.header(URI.parse(cookie_origin + "/directory")).should eq "session=synthetic"
    jar.header(URI.parse("http://catalog.example.invalid/dir/book")).should eq "parent=yes"
    ["https://example.invalid/dir", "https://sub.catalog.example.invalid/dir", "https://files.example.invalid/dir"].each { |url| jar.header(URI.parse(url)).should be_nil }
  end

  it "applies expiry replacement and deletion atomically while preserving other hosts" do
    now = Time.utc(2026, 10, 28)
    jar = AnnasArchive::CookieSession.new(-> { now })
    jar.import_netscape(export_cookie, cookie_origin)
    jar.import_netscape(export_cookie("other", "kept", "files.example.invalid"), "https://files.example.invalid")
    jar.import_netscape([export_cookie("session", "replaced"), export_cookie("old", "no", expiry: "1"), export_cookie("soon", "yes", expiry: (now + 1.second).to_unix.to_s)].join('\n'), cookie_origin)
    jar.header(URI.parse(cookie_origin)).should eq "session=replaced; soon=yes"
    now += 2.seconds
    jar.header(URI.parse(cookie_origin)).should eq "session=replaced"
    jar.import_netscape(export_cookie(expiry: "1"), cookie_origin)
    jar.header(URI.parse(cookie_origin)).should be_nil
    jar.header(URI.parse("https://files.example.invalid")).should eq "other=kept"
  end

  it "rejects malformed bytes flags prefixes and injection without partial mutation" do
    invalid = ["malformed", export_cookie("bad name"), export_cookie(value: "x;injection"), export_cookie(value: "x\rHeader: value"), export_cookie(value: "x\0"), export_cookie(value: String.new(Bytes[255])), export_cookie(path: "relative"), export_cookie(expiry: "-1"), export_cookie(expiry: "999999999999999999"), export_cookie("__Secure-bad", secure: false), export_cookie("__Host-bad", subdomains: true), export_cookie("__Host-bad", path: "/dir"), export_cookie.sub("TRUE", "maybe")]
    jar = AnnasArchive::CookieSession.new
    jar.import_netscape(export_cookie, cookie_origin)
    invalid.each do |line|
      error = expect_raises(AnnasArchive::Error) { jar.import_netscape(export_cookie("new") + "\n" + line, cookie_origin) }
      error.code.should eq "cookie_import_invalid"
      error.message.should eq error.code
      jar.header(URI.parse(cookie_origin)).should eq "session=synthetic"
    end
    jar.import_netscape(export_cookie("__Host-good"), cookie_origin)
    jar.header(URI.parse(cookie_origin)).not_nil!.should contain "__Host-good=synthetic"
    expect_raises(AnnasArchive::Error, "cookie_import_invalid") { jar.import_netscape(export_cookie, "http://catalog.example.invalid") }
  end

  it "bounds bytes lines cookie size and merged jar capacity with all-or-nothing overflow" do
    jar = AnnasArchive::CookieSession.new
    ["#" * 65_537, "#\n" * 257, "#" * 2049, export_cookie(value: "x" * 1024)].each do |input|
      expect_raises(AnnasArchive::Error, "cookie_import_too_large") { jar.import_netscape(input, cookie_origin) }
      jar.header(URI.parse(cookie_origin)).should be_nil
    end
    expect_raises(AnnasArchive::Error, "cookie_import_too_large") { jar.import_netscape(IO::Memory.new("#" * 65_537), cookie_origin) }
    jar.import_netscape((1..32).map { |i| export_cookie("c#{i}") }.join('\n'), cookie_origin)
    before = jar.header(URI.parse(cookie_origin))
    expect_raises(AnnasArchive::Error, "cookie_import_capacity") { jar.import_netscape(export_cookie("c1", "changed") + "\n" + export_cookie("overflow"), cookie_origin) }
    jar.header(URI.parse(cookie_origin)).should eq before
    jar.import_netscape(export_cookie("c1", "changed"), cookie_origin)
    jar.header(URI.parse(cookie_origin)).not_nil!.should contain "c1=changed"
  end

  it "reads only explicit synthetic files and closes unreadable errors" do
    path = File.join(__DIR__, ".synthetic-cookies-#{Random::Secure.hex(4)}.txt")
    File.write(path, export_cookie)
    jar = AnnasArchive::CookieSession.new
    jar.import_netscape_file(path, cookie_origin)
    jar.header(URI.parse(cookie_origin)).should eq "session=synthetic"
    File.delete(path)
    error = expect_raises(AnnasArchive::Error, "cookie_import_unreadable") { jar.import_netscape_file(path, cookie_origin) }
    error.message.should eq error.code
    expect_raises(AnnasArchive::Error, "cookie_import_unreadable") { jar.import_netscape(UnreadableCookieIO.new, cookie_origin) }
  ensure
    File.delete(path) if path && File.exists?(path)
  end
end

private class BrowserResolver < AnnasArchive::PublicResolver
  def resolve(host : String, context : AnnasArchive::TransferContext) : Array(String)
    context.check!
    ["8.8.8.8"]
  end
end

private class BrowserTransport < AnnasArchive::NativeHTTPTransport
  getter requests = [] of {String, HTTP::Headers}

  def initialize(cookies, user_agent, @responses : Array({Int32, HTTP::Headers, String}))
    super(BrowserResolver.new, cookies: cookies, user_agent: user_agent)
  end

  protected def proxy_configured? : Bool
    false
  end

  protected def exchange(uri : URI, address : String, context : AnnasArchive::TransferContext, headers : HTTP::Headers, &block : AnnasArchive::StreamResponse -> Nil) : Nil
    status, fields, body = @responses[@requests.size]
    @requests << {uri.to_s, headers}
    yield AnnasArchive::StreamResponse.new(status, fields, IO::Memory.new(body))
  end
end

describe "custom User-Agent and imported native session" do
  it "validates headers before transport and accepts explicit factory options" do
    ["", " ", "x" * 513, "x\r\ny: z", "x\t", "x\0", "é"].each do |agent|
      expect_raises(AnnasArchive::Error, "invalid_input") { AnnasArchive::NativeHTTPTransport.new(user_agent: agent) }
    end
    jar = AnnasArchive::CookieSession.new
    AnnasArchive::Acquisition.new(cookie_origin, cookies: jar, user_agent: "SyntheticBrowser/1.0")
  end

  it "sends one configured agent across metadata retry landing and file without leaking cookies" do
    jar = AnnasArchive::CookieSession.new
    jar.import_netscape(export_cookie, cookie_origin)
    data = "body"
    md5 = Digest::MD5.hexdigest(data)
    transport = BrowserTransport.new(jar, "SyntheticBrowser/1.0", [
      {403, HTTP::Headers.new, "<title>Just a moment</title>"},
      {200, HTTP::Headers.new, %(<div class="text-3xl">Book</div><a class="js-download-link" href="/landing">Slow</a>)},
      {200, HTTP::Headers{"Content-Type" => "text/html"}, %(<a download href="https://files.example.invalid/file">Get</a>)},
      {200, HTTP::Headers.new, data},
    ])
    now = Time::Span.zero
    client = AnnasArchive::Acquisition.new(cookie_origin, transport, delay_seconds: 1, clock: -> { now }, sleeper: ->(span : Time::Span) { now += span; nil })
    dir = File.join(__DIR__, ".anna-browser-#{Random::Secure.hex(4)}")
    Dir.mkdir(dir, mode: 0o700)
    client.record(md5, File.join(dir, "book"))
    transport.requests.size.should eq 4
    transport.requests.each { |_, headers| headers["User-Agent"].should eq "SyntheticBrowser/1.0" }
    transport.requests.first(3).each { |_, headers| headers["Cookie"].should eq "session=synthetic" }
    transport.requests.last[1]["Cookie"]?.should be_nil
  ensure
    FileUtils.rm_rf(dir) if dir
  end
end

describe "native redirected automatic naming" do
  it "names from the final redirect response without another file fetch" do
    jar = AnnasArchive::CookieSession.new
    transport = BrowserTransport.new(jar, "SyntheticBrowser/1.0", [
      {302, HTTP::Headers{"Location" => "/directory/final%20book.epub?sig=synthetic"}, ""},
      {200, HTTP::Headers.new, "body"},
    ])
    client = AnnasArchive::Acquisition.new(cookie_origin, transport)
    dir = File.join(__DIR__, ".anna-redirect-name-#{Random::Secure.hex(4)}")
    Dir.mkdir(dir, mode: 0o700)
    result = client.download("https://files.example.invalid/start", expected_md5: Digest::MD5.hexdigest("body"), directory: dir)
    result.path.should eq File.join(dir, "final book.epub")
    transport.requests.size.should eq 2
    transport.requests.last[0].should eq "https://files.example.invalid/directory/final%20book.epub?sig=synthetic"
    Dir.children(dir).should eq ["final book.epub"]
  ensure
    FileUtils.rm_rf(dir) if dir
  end
end
