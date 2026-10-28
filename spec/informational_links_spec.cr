require "spec"
require "file_utils"
require "../src/annas_archive"

private def informational_page(urls)
  %(<div class="text-3xl">Record</div>) + urls.map { |url| %(<a class="js-download-link" href="#{url.gsub("&", "&amp;")}"></a>) }.join
end

private def informational_urls
  ["http://files.example.invalid/book", "magnet:?xt=urn:btih:synthetic&dn=Book", "ipfs://synthetic-cid/book", "/fast_download/member", "https://files.example.invalid/book?x=1&x=2&empty="]
end

private class InformationalFixture < AnnasArchive::StreamTransport
  getter requests = [] of String

  def initialize(@urls : Array(String))
  end

  def open(url : String, context : AnnasArchive::TransferContext, &block : AnnasArchive::StreamResponse -> Nil) : Nil
    @requests << url
    body = @requests.size == 1 ? informational_page(@urls) : "body"
    yield AnnasArchive::StreamResponse.new(200, HTTP::Headers.new, IO::Memory.new(body))
  end
end

describe "informational sources versus fetch capability" do
  it "retains schemes labels kinds dedupe signed queries and document order" do
    links = AnnasArchive::Parser.detail(informational_page(informational_urls + informational_urls), "a" * 32, "https://catalog.example.invalid").links
    links.map(&.url).should eq informational_urls.map { |url| url.starts_with?('/') ? "https://catalog.example.invalid" + url : url }
    links.map(&.scheme).should eq ["http", "magnet", "ipfs", "https", "https"]
    links.map(&.fetchable?).should eq [false, false, false, true, true]
    links.map(&.kind).should eq ["external", "external", "external", "member", "external"]
    links.map(&.label).should eq ["files.example.invalid", "magnet", "synthetic-cid", "catalog.example.invalid", "files.example.invalid"]
    AnnasArchive::Link.new("https://127.0.0.1/book", "external").fetchable?.should be_false
    opaque = AnnasArchive::Parser.detail(informational_page(["ipfs:/synthetic-cid/book"]), "a" * 32, "https://catalog.example.invalid").links.first
    opaque.url.should eq "ipfs:/synthetic-cid/book"
    opaque.fetchable?.should be_false
  end

  it "counts informational links toward existing bounded limits and rejects credential fragments and unknown schemes" do
    urls = (1..128).map { |i| "magnet:?xt=urn:btih:synthetic#{i}" }
    page = informational_page(urls)
    AnnasArchive::Parser.detail(page, "a" * 32, "https://catalog.example.invalid").links.size.should eq 128
    expect_raises(AnnasArchive::Error, "result_limit") { AnnasArchive::Parser.detail(informational_page(urls + ["ipfs://overflow/book"]), "a" * 32, "https://catalog.example.invalid") }
    rejected = ["javascript:x", "http://user:synthetic@files.example.invalid/book", "https://files.example.invalid/book#fragment"]
    AnnasArchive::Parser.detail(informational_page(rejected), "a" * 32, "https://catalog.example.invalid").links.should be_empty
  end

  it "defaults to first eligible nonmember HTTPS, preserves explicit indices and never fetches informational schemes" do
    [nil, 1, 2, 3, 5].each do |source|
      transport = InformationalFixture.new(informational_urls)
      now = Time::Span.zero
      client = AnnasArchive::Acquisition.new("https://catalog.example.invalid", transport, delay_seconds: 1,
        clock: -> { now }, sleeper: ->(span : Time::Span) { now += span; nil })
      dir = File.join(__DIR__, ".anna-links-#{Random::Secure.hex(4)}")
      Dir.mkdir(dir, mode: 0o700)
      begin
        if source && source < 4
          expect_raises(AnnasArchive::Error, "unsupported_source") { client.record(Digest::MD5.hexdigest("body"), File.join(dir, "file"), source: source) }
          transport.requests.size.should eq 1
        else
          client.record(Digest::MD5.hexdigest("body"), directory: dir, source: source)
          transport.requests.size.should eq 2
          transport.requests.last.should eq informational_urls.last
          File.read(File.join(dir, "book")).should eq "body"
        end
      ensure
        FileUtils.rm_rf(dir)
      end
    end
  end
end
