require "spec"
require "../src/annas_archive"

private def record_link_page(urls : Array(String))
  %(<div class="text-3xl">Record fixture</div>) + urls.map_with_index do |url, index|
    %(<a class="js-download-link" href="#{url.gsub("&", "&amp;")}">Link #{index}</a>)
  end.join
end

private def record_links(count : Int32)
  (0...count).map { |index| "https://files.example.invalid/book/#{index}" }
end

private def parse_record_links(urls : Array(String))
  AnnasArchive::Parser.detail(record_link_page(urls), "1" * 32, "https://catalog.example.invalid").links
end

describe "record link limits" do
  [21, AnnasArchive::MAX_RECORD_LINKS].each do |count|
    it "returns all #{count} unique valid links in document order" do
      urls = record_links(count)
      links = parse_record_links(urls)
      links.map(&.url).should eq urls
      links.map(&.label).should eq (0...count).map { |index| "Link #{index}" }
    end
  end

  it "retains all 38 observed-route links and exact signed queries after 21 member links" do
    md5 = "1" * 32
    origin = "https://catalog.example.invalid"
    query = "?sig=%2f%2F&x=1&x=2&empty=&z=%ff+%20"
    urls = (0...21).map { |index| "/fast_download/#{md5}/#{index}/0#{query}" } +
           (0...16).map { |index| "/slow_download/#{md5}/#{index}/0#{query}" } +
           ["https://files.example.invalid/book.epub#{query}"]
    links = parse_record_links(urls)
    links.size.should eq 38
    links.map(&.url).should eq urls.map { |url| url.starts_with?('/') ? origin + url : url }
    links.map(&.kind).should eq ["member"] * 21 + ["browser"] * 16 + ["external"]
  end

  it "counts only unique valid URLs at the bound and rejects the next valid URL" do
    urls = record_links(AnnasArchive::MAX_RECORD_LINKS)
    ignored = ["javascript:run()", "https://user:pass@files.example.invalid/private", "https://files.example.invalid/book#fragment"]
    mixed = ignored + urls + ignored + urls.first(32)
    parse_record_links(mixed).map(&.url).should eq urls
    expect_raises(AnnasArchive::Error, "result_limit") do
      parse_record_links(mixed + ["https://files.example.invalid/overflow"])
    end
  end

  it "retains the metadata page byte bound for record pages" do
    body = record_link_page(record_links(38)) + "x" * AnnasArchive::MAX_PAGE_BYTES
    expect_raises(AnnasArchive::Error, "page_too_large") do
      AnnasArchive::Parser.detail(body, "1" * 32, "https://catalog.example.invalid")
    end
  end
end
