require "json"
require "base64"
require "file_utils"
require "../../src/annas_archive"

class WorkflowResolver < AnnasArchive::PublicResolver
  def resolve(host : String, context : AnnasArchive::TransferContext) : Array(String)
    ["8.8.8.8"] # No actual DNS or socket connection in this fixture transport.
  end
end

class WorkflowInterruptedIO < IO
  def initialize(@data : IO::Memory)
  end

  def read(slice : Bytes) : Int32
    raise IO::Error.new("fixture interruption") if @data.pos >= 512
    @data.read(slice[0, Math.min(slice.size, 512)])
  end

  def write(slice : Bytes) : Nil
    raise IO::Error.new("unsupported")
  end
end

class WorkflowTransport < AnnasArchive::NativeHTTPTransport
  getter requests = [] of String
  @slow_calls = 0

  def initialize(@data : String, @md5 : String, @test_case : String)
    super(WorkflowResolver.new)
  end

  protected def proxy_configured? : Bool
    false # Offline only; perform below never invokes the native connection.
  end

  protected def perform(uri : URI, address : String, context : AnnasArchive::TransferContext, &block : AnnasArchive::StreamResponse -> Nil) : Nil
    @requests << uri.to_s
    status = 200
    headers = HTTP::Headers.new
    body = case uri.path
           when "/search"
             %(<a href="/md5/#{@md5}"><h3>Public Domain Fixture</h3><div class="text-gray-500">English [en], EPUB, 1 MB</div></a>)
           when "/md5/#{@md5}"
             %(<div><div class="text-2xl font-semibold">Public Domain Fixture</div><div class="text-gray-800">English [en] · EPUB · 1 MB</div></div><a class="js-download-link" href="/slow_download/#{@md5}/0/0">Slow</a>)
           when "/files/book.epub"
             status = 302
             headers["Location"] = "/data/book.epub?signature=a%2Bb"
             ""
           when "/data/book.epub"
             status = @test_case == "forbidden" ? 403 : @test_case == "server_error" ? 500 : 200
             headers["Content-Type"] = "application/epub+zip"
             headers["Content-Length"] = (@data.bytesize + (@test_case == "truncated" ? 1 : 0)).to_s
             @data
           else
             @slow_calls += 1
             @slow_calls == 1 ? "<span class='js-partner-countdown'>2</span>" : "<a download href='/files/book.epub'>Get</a>"
           end
    memory = IO::Memory.new(body)
    io = @test_case == "interrupted" && uri.path == "/data/book.epub" ? WorkflowInterruptedIO.new(memory) : memory
    yield AnnasArchive::StreamResponse.new(status, headers, io)
  end
end

fixture = JSON.parse(File.read(ARGV[0]))
rows = fixture["cases"].as_a.map do |item|
  test_case = item.as_s
  data = String.new(Base64.decode(fixture["archive_b64"].as_s))
  data = data.sub("Wholly synthetic", "Broken synthetic") if test_case == "crc_corruption"
  md5 = test_case == "mismatch" ? "0" * 32 : Digest::MD5.hexdigest(data)
  transport = WorkflowTransport.new(data, md5, test_case)
  now = Time::Span.zero
  client = AnnasArchive::Client.new("https://catalog.example.invalid", ->(url : String) { transport.page(url) }, delay_seconds: 1, clock: -> { now })
  dir = File.tempname("anna-native-")
  Dir.mkdir(dir, mode: 0o700)
  output = File.join(dir, "book.epub")
  wait = nil.as(Int32?)
  outcome = "ok"
  begin
    selected = client.search("Public Domain Fixture", "en", "epub").first
    now += 1.second
    record = client.detail(selected.md5)
    now += 1.second
    waiting = client.resolve(record.links.first.url)
    wait = waiting.wait_seconds
    now += 3.seconds
    resolution = client.resolve(record.links.first.url)
    cancelled = false
    progress = ->(bytes : Int64) { cancelled = true if test_case == "cancelled"; nil }
    AnnasArchive::Downloader.new(transport).download(resolution, output, selected.md5, "epub", -> { cancelled }, progress)
  rescue ex : AnnasArchive::Error
    outcome = case ex.code
              when "download_truncated", "download_md5_mismatch" then "integrity_error"
              when "access_denied", "download_http_error"        then "http_error"
              when "download_cancelled"                          then "cancelled"
              when "download_invalid_file"                       then "archive_invalid"
              when "download_io_error", "download_network_error" then "network_error"
              else                                                    ex.code
              end
  end
  exists = File.exists?(output)
  bytes = exists ? File.read(output) : nil
  result = {name: test_case, outcome: outcome, wait_seconds: wait, file_exists: exists, bytes: bytes.try(&.bytesize) || 0,
            md5: bytes.try { |value| Digest::MD5.hexdigest(value) }, sha256: bytes.try { |value| Digest::SHA256.hexdigest(value) },
            partial_files: Dir.children(dir).count(&.starts_with?(".anna-")), requests: transport.requests}
  FileUtils.rm_rf(dir)
  result
end
puts rows.to_json
