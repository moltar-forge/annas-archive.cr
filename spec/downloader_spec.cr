require "spec"
require "file_utils"
require "compress/zip"
require "base64"
require "json"
require "../src/annas_archive"

private class DownloadFixtureTransport < AnnasArchive::StreamTransport
  getter requests = [] of String
  property status = 200
  property headers = HTTP::Headers.new
  property payload : String
  property interrupt = false
  property after_chunk : Proc(Nil)?

  def initialize(@payload : String)
  end

  def open(url : String, context : AnnasArchive::TransferContext, &block : AnnasArchive::StreamResponse -> Nil) : Nil
    @requests << url
    io = IO::Memory.new(@payload)
    body = @interrupt ? InterruptDownloadIO.new(io) : io
    yield AnnasArchive::StreamResponse.new(@status, @headers, body)
    @after_chunk.try(&.call)
  end
end

private class InterruptDownloadIO < IO
  def initialize(@source : IO)
  end

  def read(slice : Bytes) : Int32
    raise IO::Error.new("private endpoint secret") if @source.pos >= 512
    @source.read(slice[0, Math.min(slice.size, 512)])
  end

  def write(slice : Bytes) : Nil
    raise IO::Error.new("unavailable")
  end
end

private class DeadlineDownloadIO < IO
  def initialize(@context : AnnasArchive::TransferContext)
  end

  def read(slice : Bytes) : Int32
    loop do
      @context.check!
      sleep 1.millisecond
    end
  end

  def write(slice : Bytes) : Nil
    raise IO::Error.new("unsupported")
  end
end

private class DeadlineDownloadTransport < AnnasArchive::StreamTransport
  def open(url : String, context : AnnasArchive::TransferContext, &block : AnnasArchive::StreamResponse -> Nil) : Nil
    yield AnnasArchive::StreamResponse.new(200, HTTP::Headers.new, DeadlineDownloadIO.new(context))
  end
end

private class SlowDownloadResolver < AnnasArchive::PublicResolver
  getter completed = Atomic(Bool).new(false)

  protected def lookup(host : String) : Array(String)
    interval = LibC::Timespec.new(tv_sec: 0, tv_nsec: 100_000_000)
    LibC.nanosleep(pointerof(interval), Pointer(LibC::Timespec).null)
    @completed.set(true)
    ["8.8.8.8"]
  end
end

private class UncertainDownloader < AnnasArchive::Downloader
  protected def sync_directory(directory : IO::FileDescriptor) : Nil
    raise IO::Error.new("simulated sync failure")
  end
end

private class FixedDownloadResolver < AnnasArchive::PublicResolver
  getter calls = 0

  def initialize(@answers = [["8.8.8.8"]])
  end

  def resolve(host : String, context : AnnasArchive::TransferContext) : Array(String)
    answer = @answers[Math.min(@calls, @answers.size - 1)]
    @calls += 1
    answer
  end
end

private class PolicyFixtureTransport < AnnasArchive::NativeHTTPTransport
  getter requests = [] of {String, String}

  def initialize(resolver : FixedDownloadResolver, @responses : Array(AnnasArchive::StreamResponse))
    super(resolver)
  end

  protected def proxy_configured? : Bool
    false # Offline transport never connects to any address.
  end

  protected def perform(uri : URI, address : String, context : AnnasArchive::TransferContext, &block : AnnasArchive::StreamResponse -> Nil) : Nil
    value = @responses[Math.min(@requests.size, @responses.size - 1)]
    @requests << {uri.to_s, address}
    yield value
  end
end

private class LocalStallNativeTransport < AnnasArchive::NativeHTTPTransport
  def initialize(@port : Int32)
    super(FixedDownloadResolver.new)
  end

  protected def proxy_configured? : Bool
    false # Local synthetic TCP fixture, never an Anna or other public request.
  end

  protected def connect_socket(socket : Socket, address : Socket::IPAddress, context : AnnasArchive::TransferContext) : Nil
    socket.connect(Socket::IPAddress.new("127.0.0.1", @port), timeout: context.remaining)
  end
end

private def with_download_directory(&)
  dir = File.tempname("anna-download")
  Dir.mkdir(dir, mode: 0o700)
  yield dir, File.join(dir, "book.epub")
ensure
  FileUtils.rm_rf(dir) if dir
end

private def synthetic_epub
  io = IO::Memory.new
  Compress::Zip::Writer.open(io) do |zip|
    zip.add("mimetype", IO::Memory.new("application/epub+zip"))
    zip.add("META-INF/container.xml", IO::Memory.new("<container/>"))
    zip.add("content.xhtml", IO::Memory.new("<html><body>Authorized synthetic public test content.</body></html>"))
  end
  io.to_s
end

private def download_response(status = 200, headers = HTTP::Headers.new, body = "body")
  AnnasArchive::StreamResponse.new(status, headers, IO::Memory.new(body))
end

describe AnnasArchive::Downloader do
  it "streams a verified EPUB to an atomic private output and checks ZIP CRC and SHA256" do
    data = synthetic_epub
    transport = DownloadFixtureTransport.new(data)
    transport.headers["Content-Length"] = data.bytesize.to_s
    with_download_directory do |dir, output|
      result = AnnasArchive::Downloader.new(transport).download("https://files.example.invalid/book.epub?signature=opaque", output, Digest::MD5.hexdigest(data).upcase, "epub")
      result.bytes.should eq data.bytesize
      result.sha256.should eq Digest::SHA256.hexdigest(data)
      result.validation.should eq "zip_crc"
      File.read(output).should eq data
      (File.info(output).permissions.value & 0o077).should eq 0
      Dir.children(dir).should eq ["book.epub"]
    end
  end

  it "runs search, record, countdown and explicit landing resolution through the standalone file API" do
    data = synthetic_epub
    md5 = Digest::MD5.hexdigest(data)
    now = Time::Span.zero
    pages = [] of String
    client = AnnasArchive::Client.new("https://catalog.example.invalid", ->(url : String) {
      pages << url
      body = case URI.parse(url).path
             when "/search"     then %(<a href="/md5/#{md5}"><h3>Public Domain Fixture (2020)</h3><div class="text-gray-500">English [en], EPUB, 1 MB</div></a>)
             when "/md5/#{md5}" then %(<div><div class="text-2xl font-semibold">Public Domain Fixture (2020)</div><div class="text-gray-800">English [en] · EPUB · 1 MB</div></div><a class="js-download-link" href="/slow_download/#{md5}/0/0">Slow</a>)
             else                    pages.size == 3 ? "<span class='js-partner-countdown'>2</span>" : "<a download href='https://files.example.invalid/book.epub'>Get</a>"
             end
      AnnasArchive::Response.new(200, body)
    }, delay_seconds: 1, clock: -> { now })
    selected = client.search("Public Domain Fixture", "en", "epub").first
    now += 1.second
    detail = client.detail(selected.md5)
    now += 1.second
    wait = client.resolve(detail.links.first.url)
    wait.wait_seconds.should eq 2
    with_download_directory do |dir, output|
      transport = DownloadFixtureTransport.new(data)
      downloader = AnnasArchive::Downloader.new(transport)
      expect_raises(AnnasArchive::Error, "download_wait_required") { downloader.download(wait, output, selected.md5, "epub") }
      transport.requests.should be_empty
      now += 3.seconds
      resolved = client.resolve(detail.links.first.url)
      result = downloader.download(resolved, output, selected.md5, "epub")
      result.md5.should eq md5
      transport.requests.size.should eq 1
      pages.size.should eq 4
    end
  end

  it "removes private partials on mismatch, truncation, interruption, cancellation and limits" do
    data = synthetic_epub
    with_download_directory do |dir, output|
      transport = DownloadFixtureTransport.new(data)
      downloader = AnnasArchive::Downloader.new(transport)
      expect_raises(AnnasArchive::Error, "download_md5_mismatch") { downloader.download("https://files.example.invalid/book", output, "0" * 32) }
      transport.headers["Content-Length"] = (data.bytesize + 1).to_s
      expect_raises(AnnasArchive::Error, "download_truncated") { downloader.download("https://files.example.invalid/book", output, Digest::MD5.hexdigest(data)) }
      transport.headers.clear
      transport.payload = data + "padding" * 200
      transport.interrupt = true
      error = expect_raises(AnnasArchive::Error, "download_io_error") { downloader.download("https://files.example.invalid/book", output, Digest::MD5.hexdigest(data)) }
      error.message.to_s.should_not contain "secret"
      transport.interrupt = false
      transport.payload = data
      cancel = false
      progress = ->(bytes : Int64) { cancel = true; nil }
      expect_raises(AnnasArchive::Error, "download_cancelled") { downloader.download("https://files.example.invalid/book", output, Digest::MD5.hexdigest(data), cancelled: -> { cancel }, progress: progress) }
      limited = AnnasArchive::Downloader.new(transport, AnnasArchive::DownloadPolicy.new(max_bytes: 32))
      expect_raises(AnnasArchive::Error, "download_size_limit") { limited.download("https://files.example.invalid/book", output, Digest::MD5.hexdigest(data)) }
      Dir.children(dir).should be_empty
    end
  end

  it "refuses error pages and unsupported responses without publishing output" do
    with_download_directory do |dir, output|
      {401 => "authentication_required", 403 => "access_denied", 429 => "rate_limited", 500 => "download_http_error", 206 => "download_http_error"}.each do |status, code|
        transport = DownloadFixtureTransport.new("<html>private error</html>")
        transport.status = status
        expect_raises(AnnasArchive::Error, code) { AnnasArchive::Downloader.new(transport).download("https://files.example.invalid/book", output, "1" * 32) }
      end
      ["<html>login</html>", "{\"error\":true}", "<?xml version='1.0'?><error/>", ""].each do |data|
        expect_raises(AnnasArchive::Error) { AnnasArchive::Downloader.new(DownloadFixtureTransport.new(data)).download("https://files.example.invalid/book", output, Digest::MD5.hexdigest(data)) }
      end
      Dir.children(dir).should be_empty
    end
  end

  it "supports an explicitly hashed plain-text file without claiming format validation" do
    data = "Wholly synthetic plain text fixture."
    transport = DownloadFixtureTransport.new(data)
    transport.headers["Content-Type"] = "text/plain"
    with_download_directory do |dir, output|
      result = AnnasArchive::Downloader.new(transport).download("https://files.example.invalid/book.txt", output, Digest::MD5.hexdigest(data))
      result.validation.should eq "hash_only"
      File.read(output).should eq data
    end
  end

  it "does not overwrite existing files, symlinks or a concurrent publication" do
    data = synthetic_epub
    with_download_directory do |dir, output|
      File.write(output, "existing")
      transport = DownloadFixtureTransport.new(data)
      downloader = AnnasArchive::Downloader.new(transport)
      expect_raises(AnnasArchive::Error, "download_file_exists") { downloader.download("https://files.example.invalid/book", output, Digest::MD5.hexdigest(data)) }
      transport.requests.should be_empty
      File.delete(output)
      File.symlink("missing", output)
      expect_raises(AnnasArchive::Error, "download_file_exists") { downloader.download("https://files.example.invalid/book", output, Digest::MD5.hexdigest(data)) }
      File.delete(output)
      transport.after_chunk = -> { File.write(output, "concurrent"); nil }
      expect_raises(AnnasArchive::Error, "download_file_exists") { downloader.download("https://files.example.invalid/book", output, Digest::MD5.hexdigest(data)) }
      File.read(output).should eq "concurrent"
      Dir.children(dir).should eq ["book.epub"]
    end
  end

  it "bounds stalled streams and cancellation without leaving a final or private partial" do
    with_download_directory do |dir, output|
      downloader = AnnasArchive::Downloader.new(DeadlineDownloadTransport.new, AnnasArchive::DownloadPolicy.new(timeout: 20.milliseconds))
      began = Time.instant
      expect_raises(AnnasArchive::Error, "download_timeout") { downloader.download("https://files.example.invalid/book", output, "1" * 32) }
      (Time.instant - began).should be < 200.milliseconds
      cancelled = false
      spawn { sleep 5.milliseconds; cancelled = true }
      expect_raises(AnnasArchive::Error, "download_cancelled") { downloader.download("https://files.example.invalid/book", output, "1" * 32, cancelled: -> { cancelled }) }
      Dir.children(dir).should be_empty
    end
  end

  it "reports uncertain durable publication while retaining only verified complete bytes" do
    data = synthetic_epub
    with_download_directory do |dir, output|
      downloader = UncertainDownloader.new(DownloadFixtureTransport.new(data))
      expect_raises(AnnasArchive::Error, "download_publication_uncertain") { downloader.download("https://files.example.invalid/book", output, Digest::MD5.hexdigest(data), "epub") }
      File.read(output).should eq data
      Dir.children(dir).should eq ["book.epub"]
    end
  end

  it "retains server rate limits per host and never charges an immediate repeat request" do
    transport = DownloadFixtureTransport.new("rate limited")
    transport.status = 429
    transport.headers["Retry-After"] = HTTP.format_time(Time.utc + 120.seconds)
    downloader = AnnasArchive::Downloader.new(transport)
    with_download_directory do |dir, output|
      error = expect_raises(AnnasArchive::Error, "rate_limited") { downloader.download("https://files.example.invalid/book", output, "1" * 32) }
      error.retry_after.not_nil!.should be >= 118
      expect_raises(AnnasArchive::Error, "rate_limited") { downloader.download("https://files.example.invalid/book", output, "1" * 32) }
      transport.requests.size.should eq 1
      expect_raises(AnnasArchive::Error, "rate_limited") { downloader.download("https://other.example.invalid/book", output, "1" * 32) }
      transport.requests.size.should eq 2
      Dir.children(dir).should be_empty
    end
    expect_raises(AnnasArchive::Error, "download_retry_after_unsupported") { AnnasArchive::RetryDelay.seconds("99999999999999999999999") }
  end

  it "validates file format, ZIP CRC and bounded expansion before publication" do
    data = synthetic_epub
    with_download_directory do |dir, output|
      broken = "PK\u0003\u0004invalid central directory"
      expect_raises(AnnasArchive::Error, "download_invalid_file") { AnnasArchive::Downloader.new(DownloadFixtureTransport.new(broken)).download("https://files.example.invalid/book", output, Digest::MD5.hexdigest(broken), "epub") }
      fixture = JSON.parse(File.read(File.join(__DIR__, "differential", "download_cases.json")))
      corrupted = String.new(Base64.decode(fixture["archive_b64"].as_s)).sub("Wholly synthetic", "Broken synthetic")
      expect_raises(AnnasArchive::Error, "download_invalid_file") { AnnasArchive::Downloader.new(DownloadFixtureTransport.new(corrupted)).download("https://files.example.invalid/book", output, Digest::MD5.hexdigest(corrupted), "epub") }
      limit = AnnasArchive::DownloadPolicy.new(max_uncompressed_bytes: 8)
      expect_raises(AnnasArchive::Error, "download_expansion_limit") { AnnasArchive::Downloader.new(DownloadFixtureTransport.new(data), limit).download("https://files.example.invalid/book", output, Digest::MD5.hexdigest(data), "epub") }
      Dir.children(dir).should be_empty
    end
  end
end

describe AnnasArchive::NativeHTTPTransport do
  it "accepts ordinary global IPv6 while excluding special-purpose and transition prefixes" do
    AnnasArchive::PublicHTTPS.public_address?("2001:4860:4860::8888").should be_true
    AnnasArchive::PublicHTTPS.public_address?("2606:4700:4700::1111").should be_true
    %w[2001:db8::1 2001:2::1 2002:0808:0808::1 3fff::1 fc00::1 fe80::1 ::ffff:8.8.8.8].each do |address|
      AnnasArchive::PublicHTTPS.public_address?(address).should be_false
    end
  end

  it "rejects private addresses, mixed DNS and rebinding before connection and after reading" do
    url = "https://files.example.invalid/book"
    ["127.0.0.1", "10.0.0.1", "169.254.169.254", "100.64.0.1", "192.0.2.1", "::1", "::ffff:8.8.8.8", "2001:db8::1"].each do |ip|
      transport = PolicyFixtureTransport.new(FixedDownloadResolver.new([["8.8.8.8", ip]]), [download_response])
      expect_raises(AnnasArchive::Error, "download_address_blocked") { transport.page(url) }
      transport.requests.should be_empty
    end
    [[["8.8.8.8"], ["10.0.0.1"]], [["8.8.8.8"], ["1.1.1.1"], ["127.0.0.1"]]].each_with_index do |answers, index|
      transport = PolicyFixtureTransport.new(FixedDownloadResolver.new(answers), [download_response])
      expect_raises(AnnasArchive::Error, "download_address_blocked") { transport.page(url) }
      transport.requests.size.should eq index
    end
  end

  it "discards captured bytes if DNS rebinds after streaming and rejects malformed URL targets" do
    data = synthetic_epub
    with_download_directory do |dir, output|
      transport = PolicyFixtureTransport.new(FixedDownloadResolver.new([["8.8.8.8"], ["1.1.1.1"], ["127.0.0.1"]]), [download_response(200, HTTP::Headers.new, data)])
      expect_raises(AnnasArchive::Error, "download_address_blocked") { AnnasArchive::Downloader.new(transport).download("https://files.example.invalid/book", output, Digest::MD5.hexdigest(data), "epub") }
      Dir.children(dir).should be_empty
    end
    ["http://files.example.invalid/book", "https://user:secret@files.example.invalid/book", "https://files.example.invalid:8443/book", "https://127.0.0.1/book", "https://[::1]/book", "https://2130706433/book", "https://files.example.invalid/book#fragment", "https://files.example.invalid\\@evil.invalid/book"].each do |url|
      error = expect_raises(AnnasArchive::Error, "download_url_blocked") { AnnasArchive::PublicHTTPS.uri(url) }
      error.message.should eq "download_url_blocked"
    end
  end

  it "pins the second public answer and follows only bounded same-host HTTPS redirects" do
    transport = PolicyFixtureTransport.new(FixedDownloadResolver.new([["8.8.8.8"], ["1.1.1.1"]]), [download_response(302, HTTP::Headers{"Location" => "/final?signature=a%2Bb"}), download_response])
    transport.page("https://files.example.invalid/book").body.should eq "body"
    transport.requests.first[1].should eq "1.1.1.1"
    transport.requests.last[0].should eq "https://files.example.invalid/final?signature=a%2Bb"
    ["https://other.example.invalid/file", "http://files.example.invalid/file", "https://127.0.0.1/file"].each do |location|
      rejected = PolicyFixtureTransport.new(FixedDownloadResolver.new, [download_response(302, HTTP::Headers{"Location" => location})])
      expect_raises(AnnasArchive::Error) { rejected.page("https://files.example.invalid/book") }
      rejected.requests.size.should eq 1
    end
    looped = PolicyFixtureTransport.new(FixedDownloadResolver.new, [download_response(302, HTTP::Headers{"Location" => "/loop"})])
    expect_raises(AnnasArchive::Error, "download_redirect_limit") { looped.page("https://files.example.invalid/book") }
    looped.requests.size.should eq 4
  end

  it "bounds blocking DNS without leaking more resolver workers after timeout" do
    resolver = SlowDownloadResolver.new
    began = Time.instant
    expect_raises(AnnasArchive::Error, "download_timeout") { resolver.resolve("fixture.invalid", AnnasArchive::TransferContext.new(20.milliseconds)) }
    (Time.instant - began).should be < 150.milliseconds
    expect_raises(AnnasArchive::Error, "download_resolver_busy") { resolver.resolve("fixture.invalid", AnnasArchive::TransferContext.new) }
    deadline = Time.instant + 500.milliseconds
    until resolver.completed.get
      fail "offline resolver worker did not finish" if Time.instant >= deadline
      sleep 1.millisecond
    end
    sleep 5.milliseconds
  end

  it "bounds an actual stalled TLS handshake and cancellation by closing its owned socket" do
    [false, true].each do |cancel_test|
      server = TCPServer.new("127.0.0.1", 0)
      accepted = Channel(UInt8?).new(1)
      socket = nil.as(TCPSocket?)
      spawn do
        begin
          socket = server.accept
          accepted.send(socket.not_nil!.read_byte)
        rescue IO::Error
          accepted.send(nil)
        end
      end
      cancelled = false
      spawn { sleep 10.milliseconds; cancelled = true } if cancel_test
      context = AnnasArchive::TransferContext.new(cancel_test ? 1.second : 40.milliseconds, -> { cancelled })
      began = Time.instant
      code = cancel_test ? "download_cancelled" : "download_timeout"
      expect_raises(AnnasArchive::Error, code) { LocalStallNativeTransport.new(server.local_address.port).page("https://files.example.invalid/book", context) }
      (Time.instant - began).should be < 250.milliseconds
      accepted.receive.should eq 0x16_u8
      socket.try(&.close)
      server.close
    end
  end

  it "refuses ambient proxies instead of silently making direct connections" do
    previous = ENV["HTTPS_PROXY"]?
    ENV["HTTPS_PROXY"] = "http://policy-proxy.example.invalid"
    expect_raises(AnnasArchive::Error, "download_proxy_transport_required") { AnnasArchive::NativeHTTPTransport.new.page("https://files.example.invalid/book") }
  ensure
    if previous
      ENV["HTTPS_PROXY"] = previous
    else
      ENV.delete("HTTPS_PROXY")
    end
  end
end
