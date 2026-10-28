require "spec"
require "file_utils"
require "../src/annas_archive"

private class MetadataFaultResolver < AnnasArchive::PublicResolver
  property fault : Exception? = nil

  def resolve(host : String, context : AnnasArchive::TransferContext) : Array(String)
    context.check!
    if fault = @fault
      raise fault
    end
    ["8.8.8.8"]
  end
end

private class MetadataLookupFaultResolver < AnnasArchive::PublicResolver
  def initialize(@fault : Exception)
  end

  protected def lookup(host : String) : Array(String)
    raise @fault
  end
end

private class MetadataFaultTransport < AnnasArchive::NativeHTTPTransport
  property fault : Exception? = nil
  getter contexts = [] of AnnasArchive::TransferContext

  def initialize(resolver = MetadataFaultResolver.new)
    super(resolver)
  end

  protected def proxy_configured? : Bool
    false
  end

  protected def exchange(uri : URI, address : String, context : AnnasArchive::TransferContext, headers : HTTP::Headers, &block : AnnasArchive::StreamResponse -> Nil) : Nil
    @contexts << context
    if fault = @fault
      raise fault
    end
    yield AnnasArchive::StreamResponse.new(200, HTTP::Headers.new, IO::Memory.new("<p>No results</p>"))
  end
end

private def metadata_fault_client(transport)
  now = Time::Span.zero
  AnnasArchive::Acquisition.new("https://catalog.example.invalid", transport, delay_seconds: 1,
    clock: -> { now }, sleeper: ->(duration : Time::Span) { now += duration; nil })
end

private def metadata_fault_directory(&)
  dir = File.tempname("anna-metadata-fault")
  Dir.mkdir(dir, mode: 0o700)
  yield dir, File.join(dir, "comic.cbz")
ensure
  FileUtils.rm_rf(dir) if dir
end

describe "native metadata exception boundary" do
  it "propagates resolver programmer faults through Acquisition.healthcheck" do
    resolver = MetadataFaultResolver.new
    fault = ArgumentError.new("synthetic resolver programmer fault")
    resolver.fault = fault
    transport = MetadataFaultTransport.new(resolver)
    client = metadata_fault_client(transport)
    expect_raises(ArgumentError) { client.healthcheck }.should be fault
    transport.contexts.should be_empty
    resolver.fault = nil
    client.healthcheck.status.should eq AnnasArchive::HealthStatus::Working
    transport.contexts.last.metadata?.should be_false
  end

  it "propagates exchange programmer faults and restores the owned context after failure" do
    transport = MetadataFaultTransport.new
    fault = ArgumentError.new("synthetic exchange programmer fault")
    transport.fault = fault
    client = metadata_fault_client(transport)
    expect_raises(ArgumentError) { client.healthcheck }.should be fault
    transport.contexts.last.metadata?.should be_false
    transport.fault = nil
    client.healthcheck.status.should eq AnnasArchive::HealthStatus::Working
    transport.contexts.last.metadata?.should be_false
  end

  it "propagates resolver-worker programmer faults but closes expected lookup IO failures" do
    fault = ArgumentError.new("synthetic worker programmer fault")
    transport = MetadataFaultTransport.new(MetadataLookupFaultResolver.new(fault))
    expect_raises(ArgumentError) { metadata_fault_client(transport).healthcheck }.should be fault
    transport = MetadataFaultTransport.new(MetadataLookupFaultResolver.new(IO::Error.new("synthetic private DNS data")))
    metadata_fault_client(transport).healthcheck.should eq AnnasArchive::HealthCheck.new(AnnasArchive::HealthStatus::Network, "download_dns_failed")
    metadata_fault_directory do |dir, path|
      transport = MetadataFaultTransport.new(MetadataLookupFaultResolver.new(fault))
      expect_raises(AnnasArchive::Error, "download_dns_failed") do
        AnnasArchive::Downloader.new(transport).download("https://catalog.example.invalid/file", path, "a" * 32, "cbz")
      end
      Dir.children(dir).should be_empty
    end
  end

  it "retains closed IO TLS and typed network errors from resolver and exchange" do
    [IO::Error.new("synthetic private IO data"), OpenSSL::Error.new("synthetic private TLS data"), AnnasArchive::Error.new("download_dns_failed")].each do |fault|
      [true, false].each do |resolver_fault|
        resolver = MetadataFaultResolver.new
        transport = MetadataFaultTransport.new(resolver)
        if resolver_fault
          resolver.fault = fault
        else
          transport.fault = fault
        end
        code = fault.is_a?(AnnasArchive::Error) ? fault.code : "download_network_error"
        metadata_fault_client(transport).healthcheck.should eq AnnasArchive::HealthCheck.new(AnnasArchive::HealthStatus::Network, code)
      end
    end
  end

  it "preserves direct-file closed errors and partial cleanup after metadata calls" do
    [true, false].each do |resolver_fault|
      resolver = MetadataFaultResolver.new
      transport = MetadataFaultTransport.new(resolver)
      client = metadata_fault_client(transport)
      client.healthcheck.status.should eq AnnasArchive::HealthStatus::Working
      fault = ArgumentError.new("synthetic private file callback data")
      if resolver_fault
        resolver.fault = fault
      else
        transport.fault = fault
      end
      metadata_fault_directory do |dir, path|
        error = expect_raises(AnnasArchive::Error, "download_network_error") do
          client.download("https://catalog.example.invalid/file", path, "a" * 32, format: "cbz")
        end
        error.message.should eq "download_network_error"
        Dir.children(dir).should be_empty
        error = expect_raises(AnnasArchive::Error, "download_network_error") do
          AnnasArchive::Downloader.new(transport).download("https://catalog.example.invalid/file", path, "a" * 32, "cbz")
        end
        error.message.should eq "download_network_error"
        Dir.children(dir).should be_empty
      end
      transport.contexts.each { |context| context.metadata?.should be_false }
    end
  end
end
