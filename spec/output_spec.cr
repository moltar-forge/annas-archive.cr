require "spec"
require "file_utils"
require "../src/annas_archive"

private class NamedFixture < AnnasArchive::StreamTransport
  getter requests = [] of String
  property headers = HTTP::Headers.new
  property status = 200
  property after : Proc(Nil)? = nil
  property final_url : String? = nil

  def initialize(@body = "body")
  end

  def open(url : String, context : AnnasArchive::TransferContext, &block : AnnasArchive::StreamResponse -> Nil) : Nil
    @requests << url
    yield AnnasArchive::StreamResponse.new(@status, @headers, IO::Memory.new(@body), @final_url)
    @after.try(&.call)
  end
end

private def named_directory(&)
  dir = File.join(__DIR__, ".anna-output-#{Random::Secure.hex(6)}")
  Dir.mkdir(dir, mode: 0o700)
  yield dir
ensure
  FileUtils.rm_rf(dir) if dir
end

private def named_client(transport)
  now = Time::Span.zero
  AnnasArchive::Acquisition.new("https://catalog.example.invalid", transport, delay_seconds: 1,
    clock: -> { now }, sleeper: ->(span : Time::Span) { now += span; nil })
end

private def named_url
  "https://files.example.invalid/file?sig=synthetic"
end

private def named_md5
  Digest::MD5.hexdigest("body")
end

describe AnnasArchive::OutputNaming do
  it "uses filename-star UTF8 precedence then ordinary filename then final URL" do
    url = "https://files.example.invalid/last.epub?sig=synthetic"
    [
      {"attachment; filename=ordinary.epub; filename*=UTF-8''%E4%B8%AD%E6%96%87.epub", "中文.epub"},
      {"attachment; filename*=utf-8'en'%2e%2e%2fchosen.epub; filename=ordinary.epub", "chosen.epub"},
      {"attachment; filename=\"quoted name.epub\"", "quoted name.epub"},
      {"attachment; filename=unquoted.epub", "unquoted.epub"},
      {"attachment; filename*=ISO-8859-1''wrong; filename=plain.epub", "plain.epub"},
      {"", "last.epub"},
      {"attachment; filename=\"\"", "download.bin"},
    ].each do |disposition, expected|
      AnnasArchive::OutputNaming.filename(HTTP::Headers{"Content-Disposition" => disposition}, url).should eq expected
    end
  end

  it "removes encoded traversal backslashes controls reserved names and keeps valid bounded UTF8" do
    {
      "../../outside.epub"                      => "outside.epub",
      "..%2f..%5coutside.epub"                  => "outside.epub",
      "CON.txt"                                 => "_CON.txt",
      "lpt9.epub"                               => "_lpt9.epub",
      "aux"                                     => "_aux",
      "NUL."                                    => "_NUL",
      ""                                        => "download.bin",
      ".."                                      => "download.bin",
      "/"                                       => "download.bin",
      "name%00%0d%0a%3c%3e%3a%22%7c%3f%2a.epub" => "name__________.epub",
      "plus+space%20.epub"                      => "plus+space .epub",
    }.each { |input, expected| AnnasArchive::OutputNaming.safe_filename(input).should eq expected }
    AnnasArchive::OutputNaming.safe_filename("CON .txt").should eq "_CON .txt"
    name = AnnasArchive::OutputNaming.safe_filename("é" * 200)
    name.bytesize.should eq 180
    name.valid_encoding?.should be_true
    AnnasArchive::OutputNaming.safe_filename("%ff.epub").valid_encoding?.should be_true
    expect_raises(AnnasArchive::Error, "download_invalid_response") { AnnasArchive::OutputNaming.safe_filename("x" * 8193) }
  end
end

describe "single-fetch output ergonomics" do
  it "creates private nested parents and selects the actual terminal response filename once" do
    fixture = NamedFixture.new
    fixture.headers["Content-Disposition"] = "attachment; filename*=UTF-8''%2e%2e%2fbook.epub"
    named_directory do |root|
      target = File.join(root, "new", "nested")
      result = named_client(fixture).download(named_url, expected_md5: named_md5, directory: target)
      result.path.should eq File.join(target, "book.epub")
      File.read(result.path).should eq "body"
      File.info(target).permissions.value.should eq 0o700
      File.info(File.dirname(target)).permissions.value.should eq 0o700
      File.info(result.path).permissions.value.should eq 0o600
      Dir.children(target).should eq ["book.epub"]
    end
    fixture.requests.should eq [named_url]
  end

  it "prefers explicit destination and prepares its parents without consulting filename metadata" do
    fixture = NamedFixture.new
    fixture.headers["Content-Disposition"] = "x" * 8193
    named_directory do |root|
      path = File.join(root, "explicit", "chosen.epub")
      result = named_client(fixture).download(named_url, path, named_md5, directory: "/ignored/unsafe")
      result.path.should eq path
      File.read(path).should eq "body"
    end
    fixture.requests.size.should eq 1
  end

  it "uses the effective final URL basename and permits default current directory" do
    fixture = NamedFixture.new
    fixture.final_url = "https://files.example.invalid/path/final%20name.epub?sig=synthetic"
    named_directory do |root|
      Dir.cd(root) do
        result = named_client(fixture).download(named_url, expected_md5: named_md5)
        result.path.should eq File.join(root, "final name.epub")
      end
    end
    fixture.requests.size.should eq 1
  end

  it "preserves existing files symlinks and racing targets without overwriting" do
    ["file", "symlink", "race", "race-symlink"].each do |mode|
      fixture = NamedFixture.new
      fixture.headers["Content-Disposition"] = "attachment; filename=book.epub"
      named_directory do |root|
        path = File.join(root, "book.epub")
        existing = File.join(root, "keep")
        File.write(existing, "existing")
        if mode == "file"
          File.write(path, "existing")
        elsif mode == "symlink"
          File.symlink(existing, path)
        else
          fixture.after = -> { mode == "race" ? File.write(path, "existing") : File.symlink(existing, path); nil }
        end
        expect_raises(AnnasArchive::Error, "download_file_exists") { named_client(fixture).download(named_url, expected_md5: named_md5, directory: root) }
        File.read(path).should eq "existing"
        File.read(existing).should eq "existing"
        Dir.children(root).sort.should eq ["book.epub", "keep"]
      end
    end
  end

  it "rejects symlink and unsafe shared ancestry before fetching and retains low-level parent policy" do
    named_directory do |root|
      safe = File.join(root, "safe")
      Dir.mkdir(safe, mode: 0o700)
      File.symlink(safe, File.join(root, "link"))
      unsafe = File.join(root, "unsafe")
      Dir.mkdir(unsafe, mode: 0o777)
      File.chmod(unsafe, 0o777)
      [File.join(root, "link", "child"), File.join(unsafe, "child")].each do |path|
        fixture = NamedFixture.new
        expect_raises(AnnasArchive::Error, "download_output_invalid") { named_client(fixture).download(named_url, expected_md5: named_md5, directory: path) }
        fixture.requests.should be_empty
      end
      fixture = NamedFixture.new
      downloader = AnnasArchive::Downloader.new(fixture)
      expect_raises(AnnasArchive::Error) { downloader.download(named_url, File.join(root, "not-created", "explicit"), named_md5) }
      File.exists?(File.join(root, "not-created")).should be_false
      fixture.requests.should be_empty
    end
  end

  it "detects ancestor replacement and final directory rename before publication and cleans anchored partials" do
    named_directory do |root|
      parent = File.join(root, "parent")
      Dir.mkdir(parent, mode: 0o700)
      leaf = File.join(parent, "leaf")
      Dir.mkdir(leaf, mode: 0o700)
      fixture = NamedFixture.new
      fixture.after = -> { File.rename(parent, parent + "-moved"); Dir.mkdir(parent, mode: 0o700); Dir.mkdir(leaf, mode: 0o700); nil }
      expect_raises(AnnasArchive::Error, "download_output_changed") { named_client(fixture).download(named_url, expected_md5: named_md5, directory: leaf) }
      Dir.children(leaf).should be_empty
      Dir.children(File.join(parent + "-moved", "leaf")).should be_empty
    end
  end

  it "cleans automatic output on mismatch cancellation and oversized filename headers" do
    ["mismatch", "cancel", "large"].each do |mode|
      fixture = NamedFixture.new
      fixture.headers["Content-Disposition"] = "x" * 8193 if mode == "large"
      stopped = false
      named_directory do |root|
        code = mode == "mismatch" ? "download_md5_mismatch" : mode == "cancel" ? "download_cancelled" : "download_invalid_response"
        expect_raises(AnnasArchive::Error, code) do
          named_client(fixture).download(named_url, expected_md5: mode == "mismatch" ? "a" * 32 : named_md5, directory: root,
            cancelled: -> { stopped }, progress: ->(bytes : Int64) { stopped = mode == "cancel"; nil })
        end
        Dir.children(root).should be_empty
      end
      fixture.requests.size.should eq 1
    end
  end
end

describe "automatic parent invariant races" do
  it "rejects ancestor symlink replacement even when the final directory inode is unchanged" do
    named_directory do |root|
      parent = File.join(root, "parent")
      leaf = File.join(parent, "leaf")
      Dir.mkdir(parent, mode: 0o700)
      Dir.mkdir(leaf, mode: 0o700)
      fixture = NamedFixture.new
      fixture.after = -> { File.rename(parent, parent + "-moved"); File.symlink(parent + "-moved", parent); nil }
      expect_raises(AnnasArchive::Error, "download_output_changed") { named_client(fixture).download(named_url, expected_md5: named_md5, directory: leaf) }
      Dir.children(File.join(parent + "-moved", "leaf")).should be_empty
    end
  end

  it "refuses a directory made shared writable while transferring" do
    named_directory do |root|
      fixture = NamedFixture.new
      fixture.after = -> { File.chmod(root, 0o777); nil }
      expect_raises(AnnasArchive::Error, "download_output_invalid") { named_client(fixture).download(named_url, expected_md5: named_md5, directory: root) }
      Dir.children(root).should be_empty
    end
  end
end
