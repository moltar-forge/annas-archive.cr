require "spec"
require "file_utils"
require "../src/annas_archive"

private class ComicResolver < AnnasArchive::PublicResolver
  def resolve(host : String, context : AnnasArchive::TransferContext) : Array(String)
    context.check!
    ["8.8.8.8"]
  end
end

# Real native policy/session/header path, synthetic exchanges only.
private class ComicTransport < AnnasArchive::NativeHTTPTransport
  getter requests = [] of {String, String?, String?}

  def initialize(@responses : Array({Int32, HTTP::Headers, String}))
    super(ComicResolver.new, user_agent: "MylarFixture/1.0")
  end

  protected def proxy_configured? : Bool
    false
  end

  protected def exchange(uri : URI, address : String, context : AnnasArchive::TransferContext, headers : HTTP::Headers, &block : AnnasArchive::StreamResponse -> Nil) : Nil
    status, fields, body = @responses[@requests.size]
    @requests << {uri.to_s, headers["Cookie"]?, headers["User-Agent"]?}
    yield AnnasArchive::StreamResponse.new(status, fields, IO::Memory.new(body))
  end
end

private def comic_response(body, type = "text/html", status = 200, headers = HTTP::Headers.new)
  headers["Content-Type"] = type
  {status, headers, body}
end

private def comic_archive
  io = IO::Memory.new
  Compress::Zip::Writer.open(io) { |zip| zip.add("001.jpg", IO::Memory.new("synthetic image bytes")) }
  io.to_s
end

private def comic_detail(md5, format = "cbz")
  %(<div>[en], #{format}, 12 MB</div><div class="text-3xl">Fixture Comic 001</div><a class="js-download-link" href="/fast_download/member">Member</a><a class="js-download-link" href="magnet:?xt=synthetic">Information</a><a class="js-download-link" href="/slow_download/#{md5}/0/0?sig=%2f%2B&amp;x=1&amp;x=2&amp;empty=">Slow</a>)
end

private def comic_directory(&)
  dir = File.tempname("anna-comic")
  Dir.mkdir(dir, mode: 0o700)
  yield dir
ensure
  FileUtils.rm_rf(dir) if dir
end

private class ComicClock
  property now = Time::Span.zero

  def client(transport)
    AnnasArchive::Acquisition.new("https://catalog.example.invalid", transport, delay_seconds: 1,
      clock: -> { @now }, sleeper: ->(duration : Time::Span) { @now += duration; nil })
  end
end

describe "public comic workflow" do
  it "searches selects details and acquires CRC-validated CBZ with stable sources and one signed fetch" do
    [nil, 3].each do |source|
      data = comic_archive
      md5 = Digest::MD5.hexdigest(data)
      search = %(<a href="/md5/#{md5}"><h3>Fixture Comic 001</h3><div class="text-gray-500">English [en], CBZ, 12 MB</div></a><a href="/md5/#{"b" * 32}"><h3>Fixture Comic 002</h3><div class="text-gray-500">English [en], CBR, 8 MB</div></a>)
      native = ComicTransport.new([
        comic_response(search, headers: HTTP::Headers{"Set-Cookie" => "session=synthetic; Secure; Path=/"}),
        comic_response(comic_detail(md5)), comic_response(comic_detail(md5)),
        comic_response(%(<span class="js-partner-countdown">1</span>)),
        comic_response(%(<a download href="/file.cbz?token=%2f%2B&amp;x=1&amp;x=2&amp;empty=">Get</a>)),
        comic_response(data, "application/zip", headers: HTTP::Headers{"Content-Disposition" => "attachment; filename=comic.cbz"}),
      ])
      clock = ComicClock.new
      client = clock.client(native)
      entries = client.search("Fixture Comic", formats: ["cbz", "cbr"], languages: ["en"], content: ["book_comic"], page: 2, sort: "newest")
      entries.map(&.format).should eq ["cbz", "cbr"]
      selected = entries.first
      detail = client.detail(selected.md5)
      detail.entry.md5.should eq md5
      detail.entry.format.should eq "cbz"
      detail.links.map(&.kind).should eq ["member", "external", "browser"]
      detail.links.map(&.fetchable?).should eq [true, false, true]
      waits = [] of Int32
      progress = [] of Int64
      comic_directory do |dir|
        path = source ? File.join(dir, "explicit.cbz") : nil
        file = client.record(selected.md5, path, source: source, directory: dir, format: selected.format,
          progress: ->(bytes : Int64) { progress << bytes; nil }, wait_progress: ->(left : Int32) { waits << left; nil })
        file.validation.should eq "zip_crc"
        file.md5.should eq md5
        file.sha256.should eq Digest::SHA256.hexdigest(data)
        File.read(file.path).should eq data
        File.basename(file.path).should eq(source ? "explicit.cbz" : "comic.cbz")
        Dir.children(dir).size.should eq 1
      end
      waits.should eq [2, 1, 0]
      progress.last.should eq data.bytesize
      progress.should eq progress.sort
      native.requests.size.should eq 6
      native.requests.first[0].should eq "https://catalog.example.invalid/search?q=Fixture+Comic&display=&lang=en&ext=cbz&ext=cbr&content=book_comic&sort=newest&page=2"
      native.requests[3][0].should eq native.requests[4][0]
      native.requests.last[0].should eq "https://catalog.example.invalid/file.cbz?token=%2f%2B&x=1&x=2&empty="
      native.requests[1..].each { |_, cookie, agent| cookie.should eq "session=synthetic"; agent.should eq "MylarFixture/1.0" }
      clock.now.should eq 6.seconds
    end
  end

  it "cleans matching-hash corrupt CBZ and mismatched hashes without replacing existing output" do
    data = comic_archive
    # Damage the CRC field while keeping the expected hash equal to the delivered bytes.
    corrupt = data.dup
    offset = corrupt.byte_index("PK\u0001\u0002").not_nil! + 16
    bytes = corrupt.to_slice.dup
    bytes[offset] ^= 0xff_u8
    corrupt = String.new(bytes)
    [{corrupt, Digest::MD5.hexdigest(corrupt), "download_invalid_file"}, {data, "a" * 32, "download_md5_mismatch"}].each do |body, md5, code|
      native = ComicTransport.new([comic_response(comic_detail(md5)), comic_response(body, "application/zip")])
      client = ComicClock.new.client(native)
      comic_directory do |dir|
        path = File.join(dir, "comic.cbz")
        expect_raises(AnnasArchive::Error, code) { client.record(md5, path, format: "cbz") }
        Dir.children(dir).should be_empty
      end
      native.requests.size.should eq 2
    end
    comic_directory do |dir|
      path = File.join(dir, "comic.cbz")
      File.write(path, "existing")
      md5 = Digest::MD5.hexdigest(data)
      native = ComicTransport.new([comic_response(comic_detail(md5))])
      expect_raises(AnnasArchive::Error, "download_file_exists") { ComicClock.new.client(native).record(md5, path, format: "cbz") }
      File.read(path).should eq "existing"
      Dir.children(dir).should eq ["comic.cbz"]
      native.requests.size.should eq 1
    end
  end

  it "accepts CBR only as hash plus RAR signature and rejects missing signatures" do
    # Deliberately NOT a valid RAR archive: success proves the limited boundary.
    ["Rar!\u001a\u0007\u0000synthetic", "not a RAR archive"].each do |data|
      md5 = Digest::MD5.hexdigest(data)
      native = ComicTransport.new([comic_response(comic_detail(md5, "cbr")), comic_response(data, "application/octet-stream")])
      comic_directory do |dir|
        action = -> { ComicClock.new.client(native).record(md5, File.join(dir, "comic.cbr"), format: "cbr") }
        if data.starts_with?("Rar!")
          action.call.validation.should eq "signature"
        else
          expect_raises(AnnasArchive::Error, "download_invalid_file") { action.call }
          Dir.children(dir).should be_empty
        end
      end
    end
  end
end

describe "structured mirror health" do
  it "classifies empty, layout, challenge, rate limit, HTTP and closed IO failures" do
    [
      {200, "<p>No files found</p>", AnnasArchive::HealthStatus::Working, nil},
      {200, "<p>Unknown layout</p>", AnnasArchive::HealthStatus::Layout, "unrecognized_page"},
      {403, "<title>Just a moment</title>", AnnasArchive::HealthStatus::Challenge, "browser_verification_required"},
      {429, "private body", AnnasArchive::HealthStatus::RateLimit, "rate_limited"},
      {401, "", AnnasArchive::HealthStatus::Error, "authentication_required"},
      {503, "", AnnasArchive::HealthStatus::Error, "unavailable"},
    ].each do |status, body, expected, code|
      client = AnnasArchive::Client.new("https://catalog.example.invalid", ->(_url : String) { AnnasArchive::Response.new(status, body, 17) })
      result = client.healthcheck
      result.status.should eq expected
      result.error_code.should eq code
      result.retry_after.should eq(expected.rate_limit? ? 17 : nil)
    end
    client = AnnasArchive::Client.new("https://catalog.example.invalid", ->(_url : String) { raise IO::Error.new("private URL/cookie"); AnnasArchive::Response.new(200, "") })
    client.healthcheck.should eq AnnasArchive::HealthCheck.new(AnnasArchive::HealthStatus::Network, "network_error")
    client = AnnasArchive::Client.new("https://catalog.example.invalid", ->(_url : String) { raise "programmer fault"; AnnasArchive::Response.new(200, "") })
    expect_raises(Exception, "programmer fault") { client.healthcheck }
  end

  it "retains local Client cooldowns and distinguishes nonempty probe success" do
    calls = [] of String
    now = Time::Span.zero
    client = AnnasArchive::Client.new("https://catalog.example.invalid", ->(url : String) {
      calls << url
      AnnasArchive::Response.new(200, %(<a href="/md5/#{"a" * 32}"><h3>Comic</h3></a>))
    }, clock: -> { now })
    client.healthcheck.status.should eq AnnasArchive::HealthStatus::Working
    client.healthcheck.should eq AnnasArchive::HealthCheck.new(AnnasArchive::HealthStatus::RateLimit, "rate_limited", 30)
    calls.should eq ["https://catalog.example.invalid/search?q=comic&display=&ext=cbz&ext=cbr"]
    now += 30.seconds
    client.healthcheck.status.should eq AnnasArchive::HealthStatus::Working
  end

  it "bounds health pacing by one deadline and preserves cancellation and programmer faults" do
    native = ComicTransport.new([comic_response("<p>No results</p>")])
    clock = ComicClock.new
    client = AnnasArchive::Acquisition.new("https://catalog.example.invalid", native,
      AnnasArchive::DownloadPolicy.new(timeout: 2.seconds), delay_seconds: 30,
      clock: -> { clock.now }, sleeper: ->(duration : Time::Span) { clock.now += duration; nil })
    client.healthcheck(cancelled: -> { true }).error_code.should eq "download_cancelled"
    native.requests.should be_empty
    client.healthcheck.status.should eq AnnasArchive::HealthStatus::Working
    client.healthcheck.should eq AnnasArchive::HealthCheck.new(AnnasArchive::HealthStatus::Network, "download_timeout")
    clock.now.should eq 2.seconds
    native.requests.size.should eq 1
    expect_raises(Exception, "callback fault") { client.healthcheck(cancelled: -> { raise "callback fault"; false }) }

    native = ComicTransport.new([comic_response("<p>No results</p>")])
    cancelled = false
    client = AnnasArchive::Acquisition.new("https://catalog.example.invalid", native,
      clock: -> { clock.now }, sleeper: ->(duration : Time::Span) { clock.now += duration; cancelled = true; nil })
    client.healthcheck.status.should eq AnnasArchive::HealthStatus::Working
    client.healthcheck(cancelled: -> { cancelled }).error_code.should eq "download_cancelled"
    native.requests.size.should eq 1
  end

  it "shares health challenge cookies pacing and actionable server cooldowns with comic acquisition" do
    native = ComicTransport.new([
      comic_response("<title>Just a moment</title>", status: 403, headers: HTTP::Headers{"Set-Cookie" => "session=synthetic; Secure; Path=/"}),
      comic_response("<p>No results</p>"),
      comic_response("", status: 429, headers: HTTP::Headers{"Retry-After" => "17"}),
      comic_response("<p>No files found</p>"),
    ])
    clock = ComicClock.new
    client = clock.client(native)
    client.healthcheck.status.should eq AnnasArchive::HealthStatus::Working
    clock.now.should eq 1.second
    native.requests[1][0].should end_with "&check=%31"
    native.requests[1][1].should eq "session=synthetic"
    result = client.healthcheck
    result.status.should eq AnnasArchive::HealthStatus::RateLimit
    result.retry_after.should eq 17
    comic_directory do |dir|
      error = expect_raises(AnnasArchive::Error, "rate_limited") { client.record("a" * 32, File.join(dir, "comic.cbz"), format: "cbz") }
      error.retry_after.should eq 17
      Dir.children(dir).should be_empty
    end
    client.healthcheck.retry_after.should eq 17
    native.requests.size.should eq 3
    clock.now += 17.seconds
    client.healthcheck.status.should eq AnnasArchive::HealthStatus::Working
    native.requests.size.should eq 4
  end
end
