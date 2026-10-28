require "spec"
require "../src/annas_archive"

private def reference_fixture(name)
  File.read(File.join(__DIR__, "fixtures", "reference", name + ".html"))
end

describe "Pinned reference normal-flow compatibility" do
  it "retains legacy bibliographic fields, deferred records and reconstructed record URLs" do
    entries = AnnasArchive::Parser.search(reference_fixture("search"), "https://catalog.example.invalid")
    entries.size.should eq 2
    first = entries.first
    first.author.should eq "Jane Austen"
    first.publisher.should eq "Example Press, 1813"
    first.size.should eq "1.2MB"
    first.cover_url.should eq "https://catalog.example.invalid/covers/one.jpg"
    first.url.should eq "https://catalog.example.invalid/md5/#{"1" * 32}"
    entries.last.language.should eq "zh"
  end

  it "retains current bibliographic fields while removing save controls and trailing separators" do
    entry = AnnasArchive::Parser.search(reference_fixture("search-current"), "https://catalog.example.invalid").first
    entry.author.should eq "Austen, Jane"
    entry.publisher.should eq "Project Gutenberg, 1998"
    entry.size.should eq "0.3MB"
    entry.cover_url.should be_nil
    entry.summary.should_not contain "Save"
    entry.summary.should_not end_with "·"
    detail = AnnasArchive::Parser.detail(reference_fixture("info-current"), "1" * 32, "https://catalog.example.invalid")
    detail.entry.summary.should eq entry.summary
    detail.description.should contain "Alternative author"
    detail.links.first.label.should eq "Fast Partner Server #1 ⭐️"
    detail.links[1].kind.should eq "browser"
  end

  it "extracts legacy record description and source labels without following links" do
    detail = AnnasArchive::Parser.detail(reference_fixture("info"), "1" * 32, "https://catalog.example.invalid")
    detail.description.should eq "Description A novel."
    detail.entry.author.should eq "Jane Austen"
    detail.entry.publisher.should eq "Example Press, 1813"
    detail.links.map(&.label).should eq ["Fast partner", "Slow partner", "External source"]
  end

  it "requests an explicit page with repeated filters and preserves comic title identity hints" do
    urls = [] of String
    client = AnnasArchive::Client.new("https://catalog.example.invalid", ->(url : String) { urls << url; AnnasArchive::Response.new(200, "<p>No results found</p>") })
    client.search("Example & Comic #001 (2020) (Digital)", languages: ["en", "fr"], formats: ["cbz", "epub"], content: ["book_fiction"], page: 2, sort: "newest")
    params = HTTP::Params.parse(URI.parse(urls.first).query.not_nil!)
    params.fetch_all("lang").should eq ["en", "fr"]
    params.fetch_all("ext").should eq ["cbz", "epub"]
    params["q"].should eq "Example & Comic #001 (2020) (Digital)"
    params["page"].should eq "2"
    urls.size.should eq 1
  end

  it "recognizes same-origin record identifiers without trusting foreign link targets" do
    origin = "https://catalog.example.invalid"
    html = %(<a href="#{origin}/md5/#{"1" * 32}?view=details"><h3>Example Comic 001</h3></a><a href="https://other.example.invalid/md5/#{"2" * 32}"><h3>Foreign</h3></a>)
    entries = AnnasArchive::Parser.search(html, origin)
    entries.size.should eq 1
    entries.first.url.should eq "#{origin}/md5/#{"1" * 32}"
  end

  it "keeps interleaved deferred cards in document order before applying a local limit" do
    card = ->(number : Int32) { %(<a href="/md5/#{number.to_s(16).rjust(32, '0')}"><h3>Fixture #{number}</h3></a>) }
    body = card.call(1) + "<div class='js-scroll-hidden'><!--" + card.call(2) + "--></div>" + card.call(3)
    AnnasArchive::Parser.search(body).map(&.title).should eq ["Fixture 1", "Fixture 2", "Fixture 3"]
    AnnasArchive::Parser.search(body, limit: 2).map(&.title).should eq ["Fixture 1", "Fixture 2"]
  end

  it "matches the reference CLI's local result limit without changing the search request" do
    urls = [] of String
    body = (1..51).map { |number| %(<a href="/md5/#{number.to_s(16).rjust(32, '0')}"><h3>Fixture #{number}</h3></a>) }.join
    client = AnnasArchive::Client.new("https://catalog.example.invalid", ->(url : String) { urls << url; AnnasArchive::Response.new(200, body) })
    results = client.search("Ultimate X-Men 1 2001", page: 1, limit: 20)
    results.size.should eq 20
    urls.should eq ["https://catalog.example.invalid/search?q=Ultimate+X-Men+1+2001&display=&page=1"]
  end

  it "validates new filters before transport while preserving prior scalar calls" do
    calls = 0
    client = AnnasArchive::Client.new("https://catalog.example.invalid", ->(_url : String) { calls += 1; AnnasArchive::Response.new(200, "<p>No results found</p>") })
    expect_raises(AnnasArchive::Error, "invalid_input") { client.search("Example", page: 0) }
    expect_raises(AnnasArchive::Error, "invalid_input") { client.search("Example", sort: "arbitrary") }
    expect_raises(AnnasArchive::Error, "invalid_input") { client.search("Example", languages: ["../../secret"]) }
    expect_raises(AnnasArchive::Error, "invalid_input") { client.search("Example", formats: ["nzb"]) }
    expect_raises(AnnasArchive::Error, "invalid_input") { client.search("Example", content: ["x&secret=y"]) }
    calls.should eq 0
    client.search("Example", "en", "pdf")
    calls.should eq 1
  end
end

describe "Bounded record mirror lists" do
  it "retains all ordinary links after 21 member mirrors and deduplicates 46 anchors" do
    member = (0...21).map { |n| %(<a class="js-download-link" href="/fast_download/#{"1" * 32}/#{n}/0">Member #{n}</a>) }
    slow = (0...21).map { |n| %(<a class="js-download-link" href="/slow_download/#{"1" * 32}/#{n}/0?signature=a%2Bb">Slow #{n}</a>) }
    html = %(<div class="text-3xl">Synthetic Gutenberg-like mirror list</div>) + (member + slow + slow.first(4)).join
    links = AnnasArchive::Parser.detail(html, "1" * 32, "https://catalog.example.invalid").links
    links.size.should eq 42
    links.first(21).all? { |link| link.kind == "member" }.should be_true
    links.last(21).all? { |link| link.kind == "browser" }.should be_true
    links[21].label.should eq "Slow 0"
    links.last.url.should end_with "/20/0?signature=a%2Bb"
  end

  it "accepts the exact unique bound and fails closed without silently truncating" do
    anchors = (0..AnnasArchive::MAX_RECORD_LINKS).map { |n| %(<a class="js-download-link" href="https://files.example.invalid/#{n}.epub">Source</a>) }
    title = %(<div class="text-3xl">Synthetic</div>)
    AnnasArchive::Parser.detail(title + anchors.first(AnnasArchive::MAX_RECORD_LINKS).join, "1" * 32, "https://catalog.example.invalid").links.size.should eq AnnasArchive::MAX_RECORD_LINKS
    expect_raises(AnnasArchive::Error, "result_limit") { AnnasArchive::Parser.detail(title + anchors.join, "1" * 32, "https://catalog.example.invalid") }
    repeated = anchors.first * (AnnasArchive::MAX_RECORD_ANCHORS + 1)
    expect_raises(AnnasArchive::Error, "result_limit") { AnnasArchive::Parser.detail(title + repeated, "1" * 32, "https://catalog.example.invalid") }
  end
end
