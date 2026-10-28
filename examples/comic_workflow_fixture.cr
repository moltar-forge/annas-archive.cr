require "annas_archive"
require "file_utils"

# Offline fixture: the real coordinator owns pacing/countdown/file verification.
class ComicExampleTransport < AnnasArchive::StreamTransport
  getter requests = 0
  getter md5 : String
  @slow_requests = 0

  def initialize(@archive : String)
    @md5 = Digest::MD5.hexdigest(@archive)
  end

  def open(url : String, context : AnnasArchive::TransferContext, &block : AnnasArchive::StreamResponse -> Nil) : Nil
    context.check!
    @requests += 1
    headers = HTTP::Headers{"Content-Type" => "text/html"}
    body = case URI.parse(url).path
           when "/search"
             %(<a href="/md5/#{md5}"><h3>Synthetic Comic 001</h3><div class="text-gray-500">English [en], CBZ</div></a>)
           when "/md5/#{md5}"
             %(<div>[en], CBZ</div><div class="text-3xl">Synthetic Comic 001</div><a class="js-download-link" href="/slow_download/#{md5}/0/0">Slow</a>)
           when "/comic.cbz"
             headers["Content-Type"] = "application/zip"
             headers["Content-Disposition"] = "attachment; filename=fixture.cbz"
             @archive
           else
             @slow_requests += 1
             @slow_requests == 1 ? %(<span class="js-partner-countdown">1</span>) : %(<a download href="/comic.cbz?sig=%2f%2B&amp;x=1&amp;x=2">Get</a>)
           end
    yield AnnasArchive::StreamResponse.new(200, headers, IO::Memory.new(body))
  end
end

archive = IO::Memory.new
Compress::Zip::Writer.open(archive) { |zip| zip.add("001.jpg", IO::Memory.new("synthetic image")) }
transport = ComicExampleTransport.new(archive.to_s)
now = Time::Span.zero
client = AnnasArchive::Acquisition.new("https://catalog.example.invalid", transport,
  clock: -> { now }, sleeper: ->(duration : Time::Span) { now += duration; nil })
root = File.join(Dir.current, ".anna-comic-#{Random::Secure.hex(6)}")
Dir.mkdir(root, mode: 0o700)
begin
  raise "probe failed" unless client.healthcheck.status.working?
  entries = client.search("Synthetic Comic", formats: ["cbz", "cbr"], languages: ["en"], page: 1, sort: "relevance")
  selected = entries.first # Embedding app owns issue/edition matching and selection.
  detail = client.detail(selected.md5)
  source = detail.links.index { |link| link.kind != "member" && link.fetchable? }.not_nil! + 1
  file = client.record(selected.md5, source: source, directory: root, format: selected.format)
  raise "verification failed" unless file.validation == "zip_crc" && File.read(file.path) == archive.to_s
  puts "Downloaded #{File.basename(file.path)} (#{file.validation}); #{transport.requests} synthetic requests, no network."
  # This is a verified artifact, NOT proof of comic identity or Mylar import.
ensure
  FileUtils.rm_rf(root)
end
