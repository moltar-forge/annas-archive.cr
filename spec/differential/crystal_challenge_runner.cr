require "json"
require "base64"
require "file_utils"
require "../../src/annas_archive"

class ChallengeResolver < AnnasArchive::PublicResolver
  def resolve(host : String, context : AnnasArchive::TransferContext) : Array(String)
    context.check!
    ["8.8.8.8"]
  end
end

class ChallengeTransport < AnnasArchive::NativeHTTPTransport
  getter requests = [] of NamedTuple(url: String, cookie: String?)

  def initialize(@name : String, @archive : String)
    super(ChallengeResolver.new)
  end

  protected def proxy_configured? : Bool
    false # Offline only: no socket calls below this seam.
  end

  protected def exchange(uri : URI, address : String, context : AnnasArchive::TransferContext, headers : HTTP::Headers, &block : AnnasArchive::StreamResponse -> Nil) : Nil
    context.check!
    @requests << {url: uri.to_s, cookie: headers["Cookie"]?}
    status = 200
    response_headers = HTTP::Headers.new
    body = "<p>No results found</p>"
    if @name == "query_plain403"
      status = 403
      body = "<html>ordinary denial</html>"
    elsif @name == "query_second429" && @requests.size == 2
      status = 429
      body = ""
      response_headers["Retry-After"] = "120"
    elsif @requests.size == 1 || @name.ends_with?("bounded") || @name.in?({"slow_external", "slow_encoded"})
      status = 403
      body = "<title>Just a moment</title>"
      response_headers["Set-Cookie"] = "session=test; Path=/; Secure"
    elsif @name.starts_with?("slow_")
      body = @archive
      response_headers["Content-Type"] = "application/epub+zip"
    end
    yield AnnasArchive::StreamResponse.new(status, response_headers, IO::Memory.new(body))
  end
end

origin = "https://catalog.example.invalid"
archive = String.new(Base64.decode(JSON.parse(File.read("#{__DIR__}/download_cases.json"))["archive_b64"].as_s))
md5 = Digest::MD5.hexdigest(archive)
results = %w[query_success query_bounded query_plain403 query_second429 slow_success slow_bounded slow_external slow_encoded].map do |name|
  transport = ChallengeTransport.new(name, archive)
  outcome = "ok"
  artifact = nil.as(NamedTuple(bytes: Int64, md5: String, sha256: String)?)
  directory = File.tempname("anna-challenge-comparison")
  Dir.mkdir(directory, mode: 0o700)
  begin
    if name.starts_with?("slow_")
      url = origin + "/slow_download/" + md5 + "/0/0?sig=a%2Bb&x=1&x=2&empty=&z=%ff+%20"
      url = url.sub("catalog.example.invalid", "other.example.invalid") if name == "slow_external"
      url = url.sub("/slow_download/", "/slow%5Fdownload/") if name == "slow_encoded"
      file = AnnasArchive::Downloader.new(transport, origin: origin).download(url, File.join(directory, "book.epub"), md5, "epub")
      artifact = {bytes: file.bytes, md5: file.md5, sha256: file.sha256}
    else
      client = AnnasArchive::Client.new(origin, ->(url : String) { transport.page(url) })
      raise "nonempty result" unless client.search("中文 & Austen", formats: ["epub", "pdf"]).empty?
    end
  rescue ex : AnnasArchive::Error
    outcome = ex.code
  end
  files = Dir.children(directory).size
  FileUtils.rm_rf(directory)
  {name: name, outcome: outcome, requests: transport.requests, artifact: artifact, files: files}
end
puts results.to_json
