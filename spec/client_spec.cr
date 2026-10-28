require "spec"
require "../src/annas_archive"

private def old_card(id = "1" * 32, title = "Example Comic 001 (2020)", summary = "English [en], CBZ, 12 MB")
  %(<a href="/md5/#{id}" class="js-vim-focus"><div class="text-gray-500">#{summary}</div><h3>#{title}</h3><div class="hidden">ranking</div></a>)
end

private def current_card
  %(<div><a href="/md5/#{"2" * 32}"><img src="/cover"></a><div><div><a class="js-vim-focus" href="/md5/#{"2" * 32}">Example &amp; Comic 002 (2020)<span class="hidden">rank</span></a></div><div class="text-gray-800">English [en] · CBR · 20 MB · <a href="#">Save</a></div></div></div>)
end

describe AnnasArchive::Parser do
  it "parses both observed card layouts and ignores cover/ranking controls" do
    entries = AnnasArchive::Parser.search(old_card + current_card)
    entries.map(&.title).should eq ["Example Comic 001 (2020)", "Example & Comic 002 (2020)"]
    entries.map(&.format).should eq ["cbz", "cbr"]
    entries.map(&.language).should eq ["en", "en"]
    entries.last.summary.should_not contain "Save"
  end

  it "deduplicates stable record IDs and expands only deferred result comments" do
    html = old_card + old_card + %(<div class="js-scroll-hidden"><!--#{old_card("3" * 32)}--></div>) + "<!--#{old_card("4" * 32)}-->"
    AnnasArchive::Parser.search(html).map(&.md5).should eq ["1" * 32, "3" * 32]
  end

  it "never follows external or encoded record links" do
    html = %(<a href="https://evil.invalid/md5/#{"1" * 32}"><h3>Foreign</h3></a><a href="/md5%2F#{"2" * 32}"><h3>Encoded</h3></a>)
    expect_raises(AnnasArchive::Error, "unrecognized_page") { AnnasArchive::Parser.search(html) }
  end

  it "distinguishes explicit no results from unknown pages and parked domains" do
    AnnasArchive::Parser.search("<p>No files found</p>").should be_empty
    ["<html>Welcome</html>", "<html>This domain may be for sale</html>"].each do |body|
      expect_raises(AnnasArchive::Error, "unrecognized_page") { AnnasArchive::Parser.search(body) }
    end
  end

  it "returns challenges without attempting to solve them" do
    ["<title>DDOS-Guard</title>", "<form id='challenge-form'></form>", "<script src='/challenge-platform/run'></script>"].each do |body|
      expect_raises(AnnasArchive::Error, "browser_verification_required") { AnnasArchive::Parser.search(body) }
    end
  end

  it "bounds result count and page size" do
    html = (1..51).map { |i| old_card(i.to_s(16).rjust(32, '0')) }.join
    expect_raises(AnnasArchive::Error, "result_limit") { AnnasArchive::Parser.search(html) }
    expect_raises(AnnasArchive::Error, "page_too_large") { AnnasArchive::Parser.search("x" * (AnnasArchive::MAX_PAGE_BYTES + 1)) }
  end

  it "retains multilingual and unknown metadata without inventing identity" do
    result = AnnasArchive::Parser.search(old_card(title: "漫画 001", summary: "中文 [zh], ZIP, 5 MB")).first
    result.language.should eq "zh"
    result.format.should eq "zip"
    result = AnnasArchive::Parser.search(old_card(summary: "Unknown metadata")).first
    result.language.should be_nil
    result.format.should be_nil
  end

  it "lists record links as metadata, with browser/member routes kept distinct" do
    body = %(<div><div class="text-2xl font-semibold">Example Comic 001 (2020)</div><div class="text-gray-800">English [en] · CBZ</div></div><a class="js-download-link" href="/slow_download/#{"1" * 32}/0/0">Slow</a><a class="js-download-link" href="/fast_download/#{"1" * 32}">Member</a><a class="js-download-link" href="https://files.example.invalid/a.cbz">External</a><a class="js-download-link" href="javascript:run()">Bad</a><a class="js-download-link" href="https://user:secret@files.example.invalid/a">Credentials</a>)
    detail = AnnasArchive::Parser.detail(body, "1" * 32, "https://catalog.example.invalid")
    detail.entry.format.should eq "cbz"
    detail.links.map(&.kind).should eq ["browser", "member", "external"]
    detail.links.first.url.should eq "https://catalog.example.invalid/slow_download/#{"1" * 32}/0/0"
  end

  it "rejects malformed record pages" do
    expect_raises(AnnasArchive::Error, "unrecognized_page") { AnnasArchive::Parser.detail("<html>missing</html>", "1" * 32, "https://catalog.example.invalid") }
  end

  it "parses explicit landing-page controls without rewriting signed URLs" do
    target = "https://files.example.invalid/comic.cbz?signature=opaque%2Bvalue"
    result = AnnasArchive::Parser.resolve(%(<a id="download" href="#{target}">Download</a>), "https://catalog.example.invalid/slow_download/example")
    result.url.should eq target
    result.wait_seconds.should be_nil
    result = AnnasArchive::Parser.resolve(%(<span class="js-partner-countdown">60</span>), "https://catalog.example.invalid/slow_download/example")
    result.wait_seconds.should eq 60
    result.url.should be_nil
  end

  it "rejects login, malformed waits and unknown landing pages" do
    {"<input type='password'>" => "authentication_required", "<span class='js-partner-countdown'>soon</span>" => "unrecognized_page", "<p>Please wait</p>" => "unsupported_resolution"}.each do |body, code|
      expect_raises(AnnasArchive::Error, code) { AnnasArchive::Parser.resolve(body, "https://catalog.example.invalid/slow_download/example") }
    end
  end
end

describe AnnasArchive::Client do
  it "resolves one ordinary same-origin slow page and refuses alternate encodings/hosts before transport" do
    urls = [] of String
    client = AnnasArchive::Client.new("https://catalog.example.invalid", ->(url : String) { urls << url; AnnasArchive::Response.new(200, "<span class='js-partner-countdown'>30</span>") })
    value = client.resolve("https://catalog.example.invalid/slow_download/#{"1" * 32}/0/0?signature=opaque%2Bvalue")
    value.wait_seconds.should eq 30
    urls.should eq ["https://catalog.example.invalid/slow_download/#{"1" * 32}/0/0?signature=opaque%2Bvalue"]
    ["https://other.example.invalid/slow_download/#{"1" * 32}/0/0", "https://catalog.example.invalid/slow%5Fdownload/#{"1" * 32}/0/0"].each do |url|
      expect_raises(AnnasArchive::Error, "invalid_input") { client.resolve(url) }
    end
    urls.size.should eq 1
  end
  it "encodes a bounded search using an injected transport and makes one request" do
    urls = [] of String
    client = AnnasArchive::Client.new("https://catalog.example.invalid", ->(url : String) { urls << url; AnnasArchive::Response.new(200, old_card) })
    client.search("Comic & friends", "en", "cbz").size.should eq 1
    urls.should eq ["https://catalog.example.invalid/search?q=Comic+%26+friends&display=&lang=en&ext=cbz"]
    expect_raises(AnnasArchive::Error, "rate_limited") { client.detail("1" * 32) }
    urls.size.should eq 1
  end

  it "does not retry or rewrite challenge URLs" do
    urls = [] of String
    client = AnnasArchive::Client.new("https://catalog.example.invalid", ->(url : String) { urls << url; AnnasArchive::Response.new(403, "<title>Just a moment</title>") })
    expect_raises(AnnasArchive::Error, "browser_verification_required") { client.search("Comic") }
    urls.size.should eq 1
    urls.first.should_not contain "check="
  end

  it "preserves a bounded server-requested cooldown without sleeping or retrying" do
    now = Time::Span.zero
    calls = 0
    client = AnnasArchive::Client.new("https://catalog.example.invalid", ->(_url : String) { calls += 1; AnnasArchive::Response.new(429, "", 90) }, clock: -> { now })
    ex = expect_raises(AnnasArchive::Error, "rate_limited") { client.search("Comic") }
    ex.retry_after.should eq 90
    now += 89.seconds
    expect_raises(AnnasArchive::Error, "rate_limited") { client.search("Comic") }
    calls.should eq 1
    now += 1.second
    expect_raises(AnnasArchive::Error, "rate_limited") { client.search("Comic") }
    calls.should eq 2
  end

  it "retains cooldowns reported by a policy transport's typed error" do
    now = Time::Span.zero
    calls = 0
    client = AnnasArchive::Client.new("https://catalog.example.invalid", ->(_url : String) {
      calls += 1
      raise AnnasArchive::Error.new("rate_limited", 120)
      AnnasArchive::Response.new(200, "")
    }, clock: -> { now })
    expect_raises(AnnasArchive::Error, "rate_limited") { client.search("Comic") }
    now += 60.seconds
    expect_raises(AnnasArchive::Error, "rate_limited") { client.search("Comic") }
    calls.should eq 1
  end

  it "distinguishes auth, denial and unavailable responses with safe error messages" do
    {401 => "authentication_required", 403 => "access_denied", 503 => "unavailable"}.each do |status, code|
      client = AnnasArchive::Client.new("https://catalog.example.invalid", ->(_url : String) { AnnasArchive::Response.new(status, "secret body") })
      ex = expect_raises(AnnasArchive::Error, code) { client.search("Comic") }
      ex.message.should eq code
    end
  end

  it "classifies empty error bodies and redacts transport exception text" do
    client = AnnasArchive::Client.new("https://catalog.example.invalid", ->(_url : String) { AnnasArchive::Response.new(401, "") })
    expect_raises(AnnasArchive::Error, "authentication_required") { client.search("Comic") }
    client = AnnasArchive::Client.new("https://catalog.example.invalid", ->(_url : String) {
      raise IO::Error.new("signed secret https://private.invalid/?token=secret")
      AnnasArchive::Response.new(200, "")
    })
    ex = expect_raises(AnnasArchive::Error, "network_error") { client.search("Comic") }
    ex.message.should eq "network_error"
  end

  it "honors long Retry-After values and validates queries and filters before transport" do
    calls = 0
    client = AnnasArchive::Client.new("https://catalog.example.invalid", ->(_url : String) { calls += 1; AnnasArchive::Response.new(429, "", 999999) })
    expect_raises(AnnasArchive::Error, "invalid_input") { client.search("x" * 513) }
    expect_raises(AnnasArchive::Error, "invalid_input") { client.search("Comic", language: "../../secret") }
    expect_raises(AnnasArchive::Error, "invalid_input") { client.search("Comic", format: "nzb") }
    calls.should eq 0
    ex = expect_raises(AnnasArchive::Error, "rate_limited") { client.search("Comic") }
    ex.retry_after.should eq 999999
  end

  it "validates input before calling transport" do
    calls = 0
    fetch = ->(_url : String) { calls += 1; AnnasArchive::Response.new(200, old_card) }
    ["http://catalog.example.invalid", "https://user:pass@catalog.example.invalid", "https://catalog.example.invalid/search", "https://catalog.example.invalid/?token=x"].each do |origin|
      expect_raises(AnnasArchive::Error, "invalid_input") { AnnasArchive::Client.new(origin, fetch) }
    end
    client = AnnasArchive::Client.new("https://catalog.example.invalid", fetch)
    expect_raises(AnnasArchive::Error, "invalid_input") { client.search("\n") }
    expect_raises(AnnasArchive::Error, "invalid_input") { client.detail("https://evil.invalid/md5/#{"1" * 32}") }
    calls.should eq 0
  end
end
