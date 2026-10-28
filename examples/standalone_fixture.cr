# Offline example: uses the real public API with synthetic metadata and EPUB.
# No DNS, sockets, HTTP server, CLI execution or Python runtime is involved.
require "annas_archive"
require "json"
require "base64"

class OfflineTransport < AnnasArchive::StreamTransport
  getter requests = [] of String
  getter md5 : String
  @landing_calls = 0

  def initialize(@data : String)
    @md5 = Digest::MD5.hexdigest(@data)
  end

  def open(url : String, context : AnnasArchive::TransferContext, &block : AnnasArchive::StreamResponse -> Nil) : Nil
    context.check!
    @requests << url
    headers = HTTP::Headers.new
    body = case URI.parse(url).path
           when "/search"
             %(<a href="/md5/#{md5}"><h3>Public Domain Fixture</h3><div class="text-gray-500">English [en], EPUB</div></a>)
           when "/md5/#{md5}"
             %(<div><div class="text-2xl font-semibold">Public Domain Fixture</div><div class="text-gray-800">English [en] · EPUB</div></div><a class="js-download-link" href="/slow_download/#{md5}/0/0">Slow</a>)
           when "/files/book.epub"
             headers["Content-Type"] = "application/epub+zip"
             headers["Content-Length"] = @data.bytesize.to_s
             @data
           else
             @landing_calls += 1
             @landing_calls == 1 ? "<span class='js-partner-countdown'>2</span>" : "<a download href='/files/book.epub'>Get</a>"
           end
    yield AnnasArchive::StreamResponse.new(200, headers, IO::Memory.new(body))
  end
end

fixture = JSON.parse(File.read(File.expand_path("../spec/differential/download_cases.json", __DIR__)))
transport = OfflineTransport.new(String.new(Base64.decode(fixture["archive_b64"].as_s)))
clock = Time::Span.zero
client = AnnasArchive::Client.new("https://catalog.example.invalid", ->(url : String) { transport.page(url) }, delay_seconds: 1, clock: -> { clock })
selected = client.search("Public Domain Fixture", "en", "epub").first
clock += 1.second
record = client.detail(selected.md5)
clock += 1.second
waiting = client.resolve(record.links.find { |link| link.kind == "browser" }.not_nil!.url)
# Real applications schedule the next call after wait_seconds; this offline
# example advances a fake clock rather than sleeping or making extra probes.
clock += (waiting.wait_seconds.not_nil! + 1).seconds
resolved = client.resolve(record.links.find { |link| link.kind == "browser" }.not_nil!.url)
dir = ARGV[0]? || File.tempname("anna-offline-example-")
Dir.mkdir(dir, mode: 0o700) unless Dir.exists?(dir)
result = AnnasArchive::Downloader.new(transport).download(resolved, File.join(dir, "book.epub"), selected.md5, "epub")
puts({path: result.path, bytes: result.bytes, md5: result.md5, sha256: result.sha256, validation: result.validation, requests: transport.requests.size, network: "none"}.to_json)
