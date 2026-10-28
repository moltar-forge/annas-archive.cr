require "./downloader"

module AnnasArchive
  # Session-wide scheduling is separate from server rate limits: only local
  # pacing sleeps. Every native exchange still enforces its own redirect policy.
  private class AcquisitionTransport(T) < StreamTransport
    @next_request = Time::Span.zero
    @cooldowns = {} of String => Time::Span
    property requests = 0

    def initialize(@inner : T, @origin : String, @interval : Time::Span,
                   @clock : Proc(Time::Span), @sleeper : Proc(Time::Span, Nil))
    end

    def pause(duration : Time::Span, context : TransferContext) : Nil
      until_at = @clock.call + duration
      while @clock.call < until_at
        context.check!
        before = @clock.call
        @sleeper.call(Math.min(1.second, Math.min(until_at - before, context.remaining)))
        context.check!
        raise Error.new("download_clock_stalled") unless @clock.call > before
      end
    end

    def prepare(context : TransferContext) : Nil
      check_server!(URI.parse(@origin).host.not_nil!)
      pause(@next_request - @clock.call, context)
    end

    private def check_server!(host : String) : Nil
      @cooldowns.reject! { |_, value| value <= @clock.call }
      if until_at = @cooldowns[host]?
        raise Error.new("rate_limited", (until_at - @clock.call).total_seconds.ceil.to_i.clamp(1, Int32::MAX))
      end
    end

    def open(url : String, context : TransferContext, &block : StreamResponse -> Nil) : Nil
      uri = PublicHTTPS.uri(url)
      host = uri.host.not_nil!.downcase
      check_server!(host)
      if host == URI.parse(@origin).host.try(&.downcase)
        prepare(context)
        @next_request = @clock.call + @interval
      end
      context.check!
      raise Error.new("download_request_limit") if @requests >= 64
      @requests += 1
      @inner.open(url, context) do |response|
        if response.status == 429
          delay = RetryDelay.seconds(response.headers["Retry-After"]?) || 60
          raise Error.new("download_cooldown_capacity") if @cooldowns.size >= 32 && !@cooldowns.has_key?(host)
          @cooldowns[host] = @clock.call + delay.seconds
          raise Error.new("rate_limited", delay)
        end
        yield response
      end
      context.check!
    rescue ex : Error
      # Typed transport failures must retain cooldowns too.
      if ex.code == "rate_limited" && host
        raise Error.new("download_cooldown_capacity") if @cooldowns.size >= 32 && !@cooldowns.has_key?(host)
        @cooldowns[host] = @clock.call + (ex.retry_after || 60).seconds
      end
      raise ex
    end
  end

  class Acquisition(T)
    @transport : AcquisitionTransport(T)
    @client : Client
    @downloader : Downloader
    @active_context : TransferContext? = nil
    @lock = Mutex.new

    def self.new(origin : String, cookies : CookieSession = CookieSession.new, user_agent : String = "annas-archive.cr/#{VERSION}", **options)
      Acquisition(NativeHTTPTransport).new(origin, NativeHTTPTransport.new(cookies: cookies, user_agent: user_agent), **options)
    end

    def initialize(origin : String, transport : T,
                   @policy : DownloadPolicy = DownloadPolicy.new(timeout: 300.seconds), delay_seconds : Int32 = 30,
                   @clock : Proc(Time::Span) = -> { Time.instant - CLOCK_ORIGIN },
                   sleeper : Proc(Time::Span, Nil) = ->(duration : Time::Span) { sleep duration; nil },
                   challenge_retries : Bool = true)
      @transport = AcquisitionTransport.new(transport, origin.rstrip('/'), delay_seconds.seconds, @clock, sleeper)
      @client = Client.new(origin, ->(url : String) { @transport.page(url, @active_context.not_nil!) }, delay_seconds, @clock, challenge_retries)
      @downloader = Downloader.new(@transport, @policy, origin, challenge_retries, @clock)
    end

    # Explicit record and direct URL APIs avoid ambiguous source selection.
    def record(value : String, destination : String? = nil, expected_md5 : String? = nil, source : Int32? = nil,
               format : String? = nil, max_wait : Int32 = 300, cancelled : Proc(Bool) = -> { false },
               progress : Proc(Int64, Nil)? = nil, wait_progress : Proc(Int32, Nil)? = nil, directory : String = ".") : DownloadedFile
      @lock.synchronize do
        context = start(max_wait, cancelled)
        md5 = Client.record_id(value)
        raise Error.new("download_md5_mismatch") if expected_md5 && Client.record_id(expected_md5) != md5
        raise Error.new("invalid_input") if source && source < 1
        @transport.prepare(context)
        detail = @client.detail(md5)
        link = if index = source
                 detail.links[index - 1]? || raise Error.new("invalid_source_index")
               else
                 detail.links.find { |item| item.kind != "member" && item.fetchable? } || raise Error.new("no_download_source")
               end
        raise Error.new("unsupported_source") unless link.fetchable?
        transfer(link.url, destination, md5, format, max_wait, context, progress, wait_progress, directory)
      ensure
        @active_context = nil
      end
    end

    # Named checksum keeps it mandatory when the destination is omitted.
    def download(url : String, *, expected_md5 : String, directory : String = ".", **options) : DownloadedFile
      download(url, nil, expected_md5, **options, directory: directory)
    end

    def download(url : String, destination : String?, expected_md5 : String, format : String? = nil,
                 max_wait : Int32 = 300, cancelled : Proc(Bool) = -> { false },
                 progress : Proc(Int64, Nil)? = nil, wait_progress : Proc(Int32, Nil)? = nil, directory : String = ".") : DownloadedFile
      @lock.synchronize do
        context = start(max_wait, cancelled)
        transfer(url, destination, Client.record_id(expected_md5), format, max_wait, context, progress, wait_progress, directory)
      ensure
        @active_context = nil
      end
    end

    private def start(max_wait : Int32, cancelled : Proc(Bool)) : TransferContext
      raise Error.new("invalid_input") if max_wait < 0
      @transport.requests = 0
      context = TransferContext.new(@policy.timeout, cancelled, @clock)
      context.check!
      @active_context = context
      context
    end

    private def transfer(url : String, destination : String?, md5 : String, format : String?, max_wait : Int32,
                         context : TransferContext, progress : Proc(Int64, Nil)?, wait_progress : Proc(Int32, Nil)?, directory : String) : DownloadedFile
      wait_deadline = @clock.call + max_wait.seconds
      attempts = 1
      hops = 0
      seen = Set(String).new
      landing = ->(body : String, page_url : String) do
        context.check!
        resolution = Parser.resolve(body, page_url)
        if seconds = resolution.wait_seconds
          uri = PublicHTTPS.uri(page_url)
          base = URI.parse(@client.origin)
          slow = uri.host.try(&.downcase) == base.host.try(&.downcase) && uri.port == base.port && uri.path.matches?(/\A\/slow(?:_|%5F)download\/[a-f0-9]{32}\/\d+\/\d+\/?\z/)
          delay = seconds + 1
          raise Error.new("download_wait_required", seconds) unless slow && max_wait > 0 && delay.seconds <= wait_deadline - @clock.call
          raise Error.new("download_attempt_limit") if attempts >= 6
          until_at = @clock.call + delay.seconds
          while @clock.call < until_at
            context.check!
            wait_progress.try(&.call((until_at - @clock.call).total_seconds.ceil.to_i))
            context.check!
            @transport.pause(Math.min(1.second, until_at - @clock.call), context)
          end
          wait_progress.try(&.call(0))
          context.check!
          attempts += 1
          hops = 0
          seen.clear
          page_url
        else
          hops += 1
          raise Error.new("download_landing_limit") if hops >= 4
          target = resolution.url || raise Error.new("unsupported_resolution")
          raise Error.new("download_landing_loop") if seen.includes?(target)
          seen << page_url
          PublicHTTPS.uri(target)
          target
        end
      end
      @downloader.download(url, destination, md5, format, progress: progress, shared_context: context, landing: landing, output_directory: directory, prepare_parents: true)
    end
  end
end
