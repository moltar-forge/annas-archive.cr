require "json"
require "../../src/annas_archive"

private def project(entry : AnnasArchive::Entry, links = [] of AnnasArchive::Link, description = "")
  {md5: entry.md5, url: entry.url || "", title: entry.title, language: entry.language || "", format: entry.format || "", summary: entry.summary,
   author: entry.author || "", publisher: entry.publisher || "", size: entry.size || "", cover_url: entry.cover_url || "", description: description,
   links: links.map { |link| {url: link.url, kind: link.kind, label: link.label} }}
end

origin = "https://catalog.example.invalid"
results = JSON.parse(File.read(ARGV[0])).as_a.map do |item|
  begin
    body = item["body"]?.try(&.as_s) || ""
    value = case item["kind"].as_s
            when "search"
              AnnasArchive::Parser.search(body, origin).map { |entry| project(entry) }.to_json
            when "detail"
              detail = AnnasArchive::Parser.detail(body, "1" * 32, origin)
              project(detail.entry, detail.links, detail.description).to_json
            when "landing"
              result = AnnasArchive::Parser.resolve(body, origin + "/slow_download/" + "1" * 32 + "/0/0")
              {url: result.url, wait_seconds: result.wait_seconds}.to_json
            when "redirect"
              redirect_requests = [] of String
              # Production adapters own redirect validation. This fixture models
              # a single permitted same-origin HTTPS hop, with no network I/O.
              fetch = ->(url : String) {
                redirect_requests << url
                next_url = URI.parse(url).resolve("/results?signature=a%2Bb").to_s
                raise "unexpected fixture host" unless URI.parse(next_url).host == URI.parse(origin).host
                redirect_requests << next_url
                AnnasArchive::Response.new(200, body)
              }
              client = AnnasArchive::Client.new(origin, fetch)
              count = client.search("Example").size
              {requests: redirect_requests, count: count}.to_json
            when "cooldown"
              calls = 0
              errors = [] of String
              client = AnnasArchive::Client.new(origin, ->(_url : String) { calls += 1; AnnasArchive::Response.new(item["status"].as_i, body, 90) }, clock: -> { Time::Span.zero })
              2.times do
                begin
                  client.search("Example")
                rescue ex : AnnasArchive::Error
                  errors << ex.code
                end
              end
              {request_count: calls, errors: errors}.to_json
            when "request"
              requests = [] of NamedTuple(path: String, params: Array(Array(String)))
              client = AnnasArchive::Client.new(origin, ->(url : String) {
                uri = URI.parse(url)
                requests << {path: uri.path, params: HTTP::Params.parse(uri.query.to_s).map { |k, v| [k, v] }}
                AnnasArchive::Response.new(200, "<p>No results found</p>")
              })
              filters = item["filters"].as_h
              list = ->(key : String) { filters[key]?.try { |v| v.as_a?.try(&.map(&.as_s)) || [v.as_s] } || [] of String }
              client.search(item["query"].as_s, languages: list.call("lang"), formats: list.call("ext"), content: list.call("content"), page: filters["page"]?.try(&.as_i?), sort: filters["sort"]?.try(&.as_s?))
              requests.to_json
            when "error"
              client = AnnasArchive::Client.new(origin, ->(_url : String) { AnnasArchive::Response.new(item["status"].as_i, body) })
              client.search("Example")
              {ok: true}.to_json
            else
              raise "unknown fixture"
            end
    {name: item["name"].as_s, value: JSON.parse(value)}.to_json
  rescue ex : AnnasArchive::Error
    {name: item["name"].as_s, error: ex.code}.to_json
  end
end
puts "[" + results.join(",") + "]"
