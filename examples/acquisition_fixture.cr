require "annas_archive"
require "compress/zip"
require "file_utils"
require "json"

# Synthetic public facade demonstration. No network or browser access.
class AcquisitionExampleTransport < AnnasArchive::StreamTransport
  getter requests = [] of String

  def initialize(@archive : String)
  end

  def open(url : String, context : AnnasArchive::TransferContext, &block : AnnasArchive::StreamResponse -> Nil) : Nil
    context.check!
    @requests << url
    if @requests.size == 1
      body = %(<div class="text-3xl">Synthetic book</div><a class="js-download-link" href="magnet:?xt=urn:btih:synthetic">Information only</a><a class="js-download-link" href="https://files.example.invalid/book">Fixture</a>)
      yield AnnasArchive::StreamResponse.new(200, HTTP::Headers.new, IO::Memory.new(body))
    else
      headers = HTTP::Headers{"Content-Type" => "application/epub+zip", "Content-Disposition" => "attachment; filename*=UTF-8''%2e%2e%2fFixture%20Book.epub"}
      yield AnnasArchive::StreamResponse.new(200, headers, IO::Memory.new(@archive))
    end
  end
end

archive = IO::Memory.new
Compress::Zip::Writer.open(archive) do |zip|
  zip.add("mimetype", IO::Memory.new("application/epub+zip"))
  zip.add("META-INF/container.xml", IO::Memory.new("<container/>"))
  zip.add("content.xhtml", IO::Memory.new("<html><body>Synthetic fixture.</body></html>"))
end
transport = AcquisitionExampleTransport.new(archive.to_s)
client = AnnasArchive::Acquisition.new("https://catalog.example.invalid", transport)
root = ARGV.first? || File.join(Dir.current, ".anna-facade-#{Random::Secure.hex(6)}")
created = ARGV.empty?
Dir.mkdir(root, mode: 0o700) if created
begin
  # Omitted output name, private parent preparation, inferred MD5, skips magnet.
  file = client.record(Digest::MD5.hexdigest(archive.to_s), directory: File.join(root, "private", "books"), format: "epub")
  raise "fixture verification failed" unless File.read(file.path) == archive.to_s && file.validation == "zip_crc" && transport.requests.size == 2
  puts({"name" => File.basename(file.path), "bytes" => file.bytes, "validation" => file.validation, "requests" => transport.requests.size, "network" => "none"}.to_json)
ensure
  FileUtils.rm_rf(root) if created
end
