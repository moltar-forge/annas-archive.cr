require "spec"
require "file_utils"
require "base64"
require "json"
require "../src/annas_archive"

# Source-backed synthetic sequence: Python client.py download/_download (six
# attempts/four landings, seconds+1) and CLI record source selection, pinned
# 001ab3250e9cd829e7225b6385e3fb8aac999090. No network exchange occurs here.
private class AcquisitionFixture < AnnasArchive::StreamTransport
  getter requests = [] of String
  property after : Proc(Nil)? = nil

  def initialize(@responses : Array({Int32, String, String}))
  end

  def open(url : String, context : AnnasArchive::TransferContext, &block : AnnasArchive::StreamResponse -> Nil) : Nil
    context.check!
    status, type, body = @responses[Math.min(@requests.size, @responses.size - 1)]
    @requests << url
    @after.try(&.call)
    yield AnnasArchive::StreamResponse.new(status, HTTP::Headers{"Content-Type" => type, "Retry-After" => "120"}, IO::Memory.new(body))
  end
end

private class AcquisitionClock
  property now = Time::Span.zero
  property stopped = false
  getter sleeps = [] of Time::Span

  def client(transport, timeout = 300.seconds, interval = 1)
    AnnasArchive::Acquisition.new("https://catalog.example.invalid", transport,
      AnnasArchive::DownloadPolicy.new(timeout: timeout), delay_seconds: interval,
      clock: -> { @now }, sleeper: ->(duration : Time::Span) { @sleeps << duration; @now += duration; nil })
  end
end

private def acquisition_dir(&)
  dir = File.tempname("anna-acquisition")
  Dir.mkdir(dir, mode: 0o700)
  yield dir, File.join(dir, "book.epub")
ensure
  FileUtils.rm_rf(dir) if dir
end

private def acquisition_epub
  String.new(Base64.decode(JSON.parse(File.read("#{__DIR__}/differential/download_cases.json"))["archive_b64"].as_s))
end

private def acquisition_slow
  "https://catalog.example.invalid/slow_download/#{"a" * 32}/0/0?sig=%ff+%20&x=1&x=2&empty="
end

private def acquisition_html(body)
  {200, "text/html", body}
end

private def acquisition_countdown(seconds = 1)
  acquisition_html(%(<span class="js-partner-countdown">#{seconds}</span>))
end

describe AnnasArchive::Acquisition do
  it "owns record countdown relative signed landing and single verified publication" do
    data = acquisition_epub
    md5 = Digest::MD5.hexdigest(data)
    slow = acquisition_slow
    record = %(<div>epub</div><div class="text-3xl">Fixture</div><a class="js-download-link" href="/fast_download/member">Member</a><a class="js-download-link" href="#{slow.gsub("&", "&amp;")}">Slow</a>)
    fixture = AcquisitionFixture.new([acquisition_html(record), acquisition_countdown,
                                      acquisition_html(%(<a download href="/landing?key=%ff+%20&amp;x=1&amp;x=2">Get</a>)),
                                      acquisition_html(%(<a id="download" href="https://files.example.invalid/file?signature=%2f+%20&amp;x=1&amp;x=2">Get</a>)),
                                      {200, "application/epub+zip", data}])
    clock = AcquisitionClock.new
    waits = [] of Int32
    acquisition_dir do |dir, path|
      result = clock.client(fixture).record(" HTTP://untrusted.invalid/md5/#{md5.upcase} ", path, format: "epub", wait_progress: ->(left : Int32) { waits << left; nil })
      result.validation.should eq "zip_crc"
      result.md5.should eq md5
      File.read(path).should eq data
      Dir.children(dir).should eq ["book.epub"]
    end
    waits.should eq [2, 1, 0]
    fixture.requests.size.should eq 5
    fixture.requests.first.should eq "https://catalog.example.invalid/md5/#{md5}"
    fixture.requests[1..2].should eq [slow, slow]
    fixture.requests[3].should eq "https://catalog.example.invalid/landing?key=%ff+%20&x=1&x=2"
    fixture.requests.last.should eq "https://files.example.invalid/file?signature=%2f+%20&x=1&x=2"
    clock.now.should eq 4.seconds
  end

  it "rejects negative zero oversized and external waits without sleeping" do
    [-1, 0, 1].each do |budget|
      fixture = AcquisitionFixture.new([acquisition_countdown])
      clock = AcquisitionClock.new
      acquisition_dir do |dir, path|
        expect_raises(AnnasArchive::Error, budget < 0 ? "invalid_input" : "download_wait_required") { clock.client(fixture).download(acquisition_slow, path, "a" * 32, max_wait: budget) }
        Dir.children(dir).should be_empty
      end
      clock.sleeps.should be_empty
    end
    fixture = AcquisitionFixture.new([acquisition_countdown])
    clock = AcquisitionClock.new
    acquisition_dir do |dir, path|
      expect_raises(AnnasArchive::Error, "download_wait_required") { clock.client(fixture).download("https://external.example.invalid/wait", path, "a" * 32) }
    end
    clock.sleeps.should be_empty
  end

  it "bounds persistent countdowns and aggregate elapsed wait budget" do
    [{300, "download_attempt_limit", 6}, {3, "download_wait_required", 2}].each do |budget, code, calls|
      fixture = AcquisitionFixture.new([acquisition_countdown])
      clock = AcquisitionClock.new
      acquisition_dir do |dir, path|
        expect_raises(AnnasArchive::Error, code) { clock.client(fixture).download(acquisition_slow, path, "a" * 32, max_wait: budget) }
        Dir.children(dir).should be_empty
      end
      fixture.requests.size.should eq calls
    end
  end

  it "checks cancellation during countdown and before requests" do
    fixture = AcquisitionFixture.new([acquisition_countdown])
    clock = AcquisitionClock.new
    acquisition_dir do |dir, path|
      expect_raises(AnnasArchive::Error, "download_cancelled") do
        clock.client(fixture).download(acquisition_slow, path, "a" * 32, cancelled: -> { clock.stopped }, wait_progress: ->(left : Int32) { clock.stopped = true; nil })
      end
      Dir.children(dir).should be_empty
    end
    fixture.requests.size.should eq 1
    clock.sleeps.should be_empty
  end

  it "keeps a single total deadline across pacing metadata waits and file transfer" do
    [false, true].each do |record|
      fixture = AcquisitionFixture.new(record ? [acquisition_html(%(<div class="text-3xl">Book</div><a class="js-download-link" href="#{acquisition_slow}">Slow</a>)), acquisition_countdown] : [acquisition_countdown])
      clock = AcquisitionClock.new
      acquisition_dir do |dir, path|
        expect_raises(AnnasArchive::Error, "download_timeout") do
          if record
            clock.client(fixture, 2.seconds).record("a" * 32, path)
          else
            clock.client(fixture, 1.second).download(acquisition_slow, path, "a" * 32)
          end
        end
        Dir.children(dir).should be_empty
      end
    end
    fixture = AcquisitionFixture.new([{200, "application/octet-stream", "body"}])
    clock = AcquisitionClock.new
    fixture.after = -> { clock.now += 3.seconds; nil }
    acquisition_dir do |dir, path|
      expect_raises(AnnasArchive::Error, "download_timeout") { clock.client(fixture, 2.seconds).download(acquisition_slow, path, Digest::MD5.hexdigest("body")) }
      Dir.children(dir).should be_empty
    end
  end

  it "never retries server 429 and retains cooldown without sleeping" do
    fixture = AcquisitionFixture.new([{429, "text/html", "<title>Just a moment</title>"}])
    clock = AcquisitionClock.new
    client = clock.client(fixture)
    acquisition_dir do |dir, path|
      2.times { expect_raises(AnnasArchive::Error, "rate_limited") { client.download(acquisition_slow, path, "a" * 32) } }
      Dir.children(dir).should be_empty
    end
    fixture.requests.size.should eq 1
    clock.sleeps.should be_empty
  end

  it "bounds persistent challenge to one signed slow retry" do
    fixture = AcquisitionFixture.new([acquisition_html("<title>Just a moment</title>")])
    clock = AcquisitionClock.new
    acquisition_dir do |dir, path|
      expect_raises(AnnasArchive::Error, "browser_verification_required") { clock.client(fixture).download(acquisition_slow, path, "a" * 32) }
      Dir.children(dir).should be_empty
    end
    fixture.requests.should eq [acquisition_slow, acquisition_slow.sub("/slow_download/", "/slow%5Fdownload/")]
    clock.now.should eq 1.second
  end

  it "rejects login unknown oversized self-loop cyclic and excessive landings" do
    cases = [
      {"authentication_required", [acquisition_html("<input type=password>")], 1},
      {"unsupported_resolution", [acquisition_html("<p>Unknown</p>")], 1},
      {"page_too_large", [acquisition_html("x" * (AnnasArchive::MAX_PAGE_BYTES + 1))], 1},
      {"unsupported_resolution", [acquisition_html(%(<a download href="#{acquisition_slow.gsub("&", "&amp;")}">Get</a>))], 1},
      {"download_landing_loop", [acquisition_html(%(<a download href="/second">Get</a>)), acquisition_html(%(<a download href="#{acquisition_slow.gsub("&", "&amp;")}">Get</a>))], 2},
      {"download_landing_limit", (1..5).map { |i| acquisition_html(%(<a download href="/page#{i}">Get</a>)) }, 4},
    ]
    cases.each do |code, responses, calls|
      fixture = AcquisitionFixture.new(responses)
      acquisition_dir do |dir, path|
        expect_raises(AnnasArchive::Error, code) { AcquisitionClock.new.client(fixture).download(acquisition_slow, path, "a" * 32) }
        Dir.children(dir).should be_empty
      end
      fixture.requests.size.should eq calls
    end
  end

  it "requires matching identifiers and stable one-based source selection without fallback" do
    [" AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA ", "/md5/#{"A" * 32}/", "https://foreign.invalid/md5/#{"A" * 32}"].each { |value| AnnasArchive::Client.record_id(value).should eq "a" * 32 }
    ["bad", "ftp://foreign.invalid/md5/#{"a" * 32}", "https://user:secret@foreign.invalid/md5/#{"a" * 32}"].each { |value| expect_raises(AnnasArchive::Error, "invalid_input") { AnnasArchive::Client.record_id(value) } }
    html = %(<div class="text-3xl">Book</div><a class="js-download-link" href="/fast_download/member">Member</a>)
    [nil, 0, 2].each do |index|
      fixture = AcquisitionFixture.new([acquisition_html(html)])
      acquisition_dir do |dir, path|
        expect_raises(AnnasArchive::Error, index.nil? ? "no_download_source" : index == 0 ? "invalid_input" : "invalid_source_index") { AcquisitionClock.new.client(fixture).record("a" * 32, path, source: index) }
      end
    end
    fixture = AcquisitionFixture.new([acquisition_html(html), {403, "text/plain", "denied"}])
    acquisition_dir do |dir, path|
      client = AcquisitionClock.new.client(fixture)
      expect_raises(AnnasArchive::Error, "download_md5_mismatch") { client.record("a" * 32, path, expected_md5: "b" * 32) }
      fixture.requests.should be_empty
      expect_raises(AnnasArchive::Error, "access_denied") { client.record("a" * 32, path, source: 1) }
      fixture.requests.last.should end_with "/fast_download/member"
      fixture.requests.size.should eq 2
    end
  end

  it "never overwrites and cleans failed verification with no duplicate file fetch" do
    fixture = AcquisitionFixture.new([{200, "application/epub+zip", acquisition_epub}])
    acquisition_dir do |dir, path|
      client = AcquisitionClock.new.client(fixture)
      expect_raises(AnnasArchive::Error, "download_md5_mismatch") { client.download(acquisition_slow, path, "a" * 32) }
      Dir.children(dir).should be_empty
      File.write(path, "existing")
      expect_raises(AnnasArchive::Error, "download_file_exists") { client.download(acquisition_slow, path, "a" * 32) }
      File.read(path).should eq "existing"
      fixture.requests.size.should eq 1
    end
  end
end

private class AcquisitionResolver < AnnasArchive::PublicResolver
  def resolve(host : String, context : AnnasArchive::TransferContext) : Array(String)
    context.check!
    ["8.8.8.8"]
  end
end

private class AcquisitionNative < AnnasArchive::NativeHTTPTransport
  getter requests = [] of {String, String?}

  def initialize(@responses : Array({Int32, HTTP::Headers, String}))
    super(AcquisitionResolver.new)
  end

  protected def proxy_configured? : Bool
    false
  end

  protected def exchange(uri : URI, address : String, context : AnnasArchive::TransferContext, headers : HTTP::Headers, &block : AnnasArchive::StreamResponse -> Nil) : Nil
    status, fields, body = @responses[@requests.size]
    @requests << {uri.to_s, headers["Cookie"]?}
    yield AnnasArchive::StreamResponse.new(status, fields, IO::Memory.new(body))
  end
end

describe "acquisition native session and network boundaries" do
  it "constructs the native default without contacting a service" do
    AnnasArchive::Acquisition.new("https://catalog.example.invalid")
  end

  it "retains metadata challenge cookies and resolves relative controls against the final redirected URL" do
    data = acquisition_epub
    md5 = Digest::MD5.hexdigest(data)
    native = AcquisitionNative.new([
      {403, HTTP::Headers{"Set-Cookie" => "session=fixture; Path=/; Secure"}, "<title>Just a moment</title>"},
      {200, HTTP::Headers.new, %(<div class="text-3xl">Book</div><a class="js-download-link" href="/start">Slow</a>)},
      {302, HTTP::Headers{"Location" => "/nested/landing"}, ""},
      {200, HTTP::Headers{"Content-Type" => "text/html"}, %(<a download href="file?sig=%ff+%20&amp;x=1&amp;x=2">Get</a>)},
      {200, HTTP::Headers.new, data},
    ])
    clock = AcquisitionClock.new
    acquisition_dir do |dir, path|
      clock.client(native).record(md5, path, format: "epub").md5.should eq md5
      Dir.children(dir).should eq ["book.epub"]
    end
    native.requests[1][0].should end_with "?check=%31"
    native.requests[1..].each { |_, cookie| cookie.should eq "session=fixture" }
    native.requests.last[0].should eq "https://catalog.example.invalid/nested/file?sig=%ff+%20&x=1&x=2"
  end

  it "allows explicit public HTTPS controls without forwarding cookies and still blocks cross-host redirects" do
    data = "body"
    native = AcquisitionNative.new([
      {200, HTTP::Headers{"Content-Type" => "text/html", "Set-Cookie" => "session=fixture; Path=/; Secure"}, %(<a download href="https://files.example.invalid/file">Get</a>)},
      {200, HTTP::Headers.new, data},
    ])
    acquisition_dir do |dir, path|
      AcquisitionClock.new.client(native).download(acquisition_slow, path, Digest::MD5.hexdigest(data))
    end
    native.requests.last[1].should be_nil
    native = AcquisitionNative.new([{302, HTTP::Headers{"Location" => "https://files.example.invalid/file"}, ""}])
    acquisition_dir do |dir, path|
      expect_raises(AnnasArchive::Error, "download_redirect_blocked") { AcquisitionClock.new.client(native).download(acquisition_slow, path, "a" * 32) }
      Dir.children(dir).should be_empty
    end
    native.requests.size.should eq 1
  end

  it "preserves pacing across operations, retaining cooldown expiry and metadata cancellation" do
    data = "body"
    fixture = AcquisitionFixture.new([{200, "application/octet-stream", data}])
    clock = AcquisitionClock.new
    client = clock.client(fixture, interval: 30)
    acquisition_dir do |dir, path|
      client.download(acquisition_slow, path, Digest::MD5.hexdigest(data))
      client.download(acquisition_slow, File.join(dir, "second"), Digest::MD5.hexdigest(data))
    end
    clock.now.should eq 30.seconds
    clock.sleeps.size.should eq 30
    fixture = AcquisitionFixture.new([{429, "text/plain", ""}, {200, "text/plain", data}])
    clock = AcquisitionClock.new
    client = clock.client(fixture)
    acquisition_dir do |dir, path|
      expect_raises(AnnasArchive::Error, "rate_limited") { client.download(acquisition_slow, path, "a" * 32) }
      clock.now = 120.seconds
      client.download(acquisition_slow, path, Digest::MD5.hexdigest(data))
    end
    fixture.requests.size.should eq 2
    fixture = AcquisitionFixture.new([acquisition_countdown])
    acquisition_dir do |dir, path|
      expect_raises(AnnasArchive::Error, "download_cancelled") { AcquisitionClock.new.client(fixture).record("a" * 32, path, cancelled: -> { true }) }
    end
    fixture.requests.should be_empty
  end
end

describe "acquisition budget boundary regressions" do
  it "uses the default 300 second aggregate allowance and permits exactly fitting waits" do
    fixture = AcquisitionFixture.new([acquisition_countdown(300)])
    clock = AcquisitionClock.new
    acquisition_dir do |dir, path|
      expect_raises(AnnasArchive::Error, "download_wait_required") { clock.client(fixture).download(acquisition_slow, path, "a" * 32) }.retry_after.should eq 300
    end
    clock.sleeps.should be_empty
    fixture = AcquisitionFixture.new([acquisition_countdown, {200, "application/octet-stream", "body"}])
    clock = AcquisitionClock.new
    waits = [] of Int32
    acquisition_dir do |dir, path|
      clock.client(fixture).download(acquisition_slow, path, Digest::MD5.hexdigest("body"), max_wait: 2, wait_progress: ->(left : Int32) { waits << left; nil })
    end
    waits.should eq [2, 1, 0]
  end

  it "bounds local pacing by the original deadline and cancellation" do
    fixture = AcquisitionFixture.new([acquisition_html(%(<a download href="/next">Get</a>)), {200, "text/plain", "body"}])
    clock = AcquisitionClock.new
    acquisition_dir do |dir, path|
      expect_raises(AnnasArchive::Error, "download_timeout") { clock.client(fixture, 2.seconds, 30).download(acquisition_slow, path, "a" * 32) }
      Dir.children(dir).should be_empty
    end
    fixture.requests.size.should eq 1
    clock.now.should eq 2.seconds
    clock.sleeps.size.should eq 2
    fixture = AcquisitionFixture.new([{200, "application/octet-stream", "body"}])
    clock = AcquisitionClock.new
    acquisition_dir do |dir, path|
      expect_raises(AnnasArchive::Error, "download_cancelled") do
        clock.client(fixture).download(acquisition_slow, path, Digest::MD5.hexdigest("body"), cancelled: -> { clock.stopped }, progress: ->(bytes : Int64) { clock.stopped = true; nil })
      end
      Dir.children(dir).should be_empty
    end
  end

  it "retains metadata 429 cooldowns and cannot spin on a nonadvancing injected clock" do
    fixture = AcquisitionFixture.new([{429, "text/html", "<title>Just a moment</title>"}])
    clock = AcquisitionClock.new
    client = clock.client(fixture)
    acquisition_dir do |dir, path|
      2.times { expect_raises(AnnasArchive::Error, "rate_limited") { client.record("a" * 32, path) } }
    end
    fixture.requests.size.should eq 1
    clock.sleeps.should be_empty
    fixture = AcquisitionFixture.new([acquisition_countdown])
    client = AnnasArchive::Acquisition.new("https://catalog.example.invalid", fixture, clock: -> { Time::Span.zero }, sleeper: ->(span : Time::Span) { nil })
    acquisition_dir do |dir, path|
      expect_raises(AnnasArchive::Error, "download_clock_stalled") { client.download(acquisition_slow, path, "a" * 32) }
      Dir.children(dir).should be_empty
    end
  end

  it "streams the fourth response directly without prefetching and recognizes sniffed HTML" do
    fixture = AcquisitionFixture.new([
      {200, "application/octet-stream", %(<html><a download href="/one">Get</a></html>)},
      acquisition_html(%(<a download href="/two">Get</a>)),
      acquisition_html(%(<a download href="/three">Get</a>)),
      {200, "application/octet-stream", "body"},
    ])
    acquisition_dir do |dir, path|
      AcquisitionClock.new.client(fixture).download(acquisition_slow, path, Digest::MD5.hexdigest("body"))
      File.read(path).should eq "body"
      Dir.children(dir).should eq ["book.epub"]
    end
    fixture.requests.size.should eq 4
  end
end
