require "spec"
require "../src/annas_archive"

private def set_session(jar, url, values)
  headers = HTTP::Headers.new
  values.each { |value| headers.add("Set-Cookie", value) }
  jar.retain(URI.parse(url), headers)
end

describe AnnasArchive::CookieSession do
  it "retains host cookies, default paths and RFC path boundaries without subdomain forwarding" do
    jar = AnnasArchive::CookieSession.new
    set_session(jar, "https://catalog.example.invalid/dir/page", ["root=a; Path=/", "default=b", "scoped=c; Path=/dir", "foreign=x; Domain=other.invalid", "parent=x; Domain=example.invalid", "domain=d; Domain=.catalog.example.invalid; Path=/"])
    jar.header(URI.parse("https://catalog.example.invalid/dir/next")).should eq "default=b; scoped=c; root=a; domain=d"
    jar.header(URI.parse("https://catalog.example.invalid/directory")).should eq "root=a; domain=d"
    jar.header(URI.parse("https://other.example.invalid/dir/page")).should be_nil
    jar.header(URI.parse("https://sub.catalog.example.invalid/dir/page")).should be_nil
  end

  it "respects Secure, expiry, Max-Age precedence, replacement and deletion" do
    now = Time.utc(2026, 10, 28)
    jar = AnnasArchive::CookieSession.new(-> { now })
    set_session(jar, "https://catalog.example.invalid/", ["session=one; Secure; Path=/", "exp=old; Expires=Wed, 01 Jan 2020 00:00:00 GMT", "age=short; Max-Age=2; Expires=Wed, 01 Jan 2020 00:00:00 GMT"])
    jar.header(URI.parse("https://catalog.example.invalid/")).should eq "session=one; age=short"
    jar.header(URI.parse("http://catalog.example.invalid/")).should eq "age=short"
    set_session(jar, "http://catalog.example.invalid/", ["insecure=ignored"])
    now += 3.seconds
    jar.header(URI.parse("https://catalog.example.invalid/")).should eq "session=one"
    set_session(jar, "https://catalog.example.invalid/", ["session=two; Secure; Path=/"])
    jar.header(URI.parse("https://catalog.example.invalid/")).should eq "session=two"
    set_session(jar, "https://catalog.example.invalid/", ["session=deleted; Path=/; Max-Age=-1"])
    jar.header(URI.parse("https://catalog.example.invalid/")).should be_nil
  end

  it "rejects malformed/prefix cookies and bounds memory" do
    jar = AnnasArchive::CookieSession.new
    set_session(jar, "https://catalog.example.invalid/", ["bad name=x", "bad=\"unterminated", "__Secure-bad=x", "__Host-bad=x; Secure; Domain=catalog.example.invalid; Path=/", "large=#{"x" * 1024}"])
    jar.header(URI.parse("https://catalog.example.invalid/")).should be_nil
    set_session(jar, "https://catalog.example.invalid/", (1..40).map { |i| "c#{i}=v; Path=/" })
    jar.header(URI.parse("https://catalog.example.invalid/")).not_nil!.split("; ").size.should eq 32
    set_session(jar, "https://other.example.invalid/", ["extra=ignored"])
    jar.header(URI.parse("https://other.example.invalid/")).should be_nil
  end
end

describe AnnasArchive::CookieSession do
  it "accepts quoted values and honors zero-age deletion and future expiry" do
    now = Time.utc(2026, 10, 28)
    jar = AnnasArchive::CookieSession.new(-> { now })
    set_session(jar, "https://catalog.example.invalid/", [%q(session="quoted"; Path=/), "future=x; Expires=Thu, 29 Oct 2026 00:00:00 GMT; Path=/"])
    jar.header(URI.parse("https://catalog.example.invalid/")).should eq "session=quoted; future=x"
    set_session(jar, "https://catalog.example.invalid/", ["session=delete; Max-Age=0; Path=/"])
    now += 2.days
    jar.header(URI.parse("https://catalog.example.invalid/")).should be_nil
  end
end
