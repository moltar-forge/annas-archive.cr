# annas-archive.cr

Native Crystal library for searching Anna’s Archive, reading records, resolving
download links and streaming files with hash and format validation. No Python,
CLI or browser runtime required.

**Experimental:** live search works, but end-to-end live downloads remain
unverified. Records with more than 20 download links currently fail with
`result_limit`. This is an unofficial HTML interface; site changes can break it.

## Installation

Requires Crystal 1.20+, libxml2 and OpenSSL with CA certificates. Native file
publication requires POSIX. There are no third-party shard dependencies.

Add to your `shard.yml`:

```yaml
dependencies:
  annas_archive:
    github: moltar-forge/annas-archive.cr
    branch: main
```

Run `shards install`. Pin a reviewed revision for production use.

## Search

```crystal
require "annas_archive"

origin = "https://annas-archive.gl"
transport = AnnasArchive::NativeHTTPTransport.new
client = AnnasArchive::Client.new(origin, ->(url : String) { transport.page(url) })

entries = client.search("Pride and Prejudice", language: "en", format: "epub", limit: 5)
entries.each do |entry|
  puts "#{entry.title} — #{entry.author} (#{entry.md5})"
end
```

Search returns one page of `Entry` records. Filters include language, format,
content type, sort and page. Clients enforce a 30-second minimum request interval
by default; callers schedule later requests and handle `rate_limited` errors.

## Records and downloads

- `client.detail(md5)` returns metadata, a description and download links.
- `client.resolve(url)` reads a same-origin slow-download landing page and returns
  a `Resolution` containing a file URL or countdown. Callers schedule countdowns.
- `Downloader#download` accepts a URL or resolved `Resolution`, destination,
  expected MD5 and optional format. It returns the path, byte count, MD5, SHA-256
  and validation result. Share the client’s transport to retain session cookies.

Downloads validate hashes before atomic publication and never overwrite existing
files. EPUB/ZIP-based formats also receive archive checks. Use a caller-owned
output directory that is not group/world writable.

See the [API reference](docs/api.md) for examples, filters, errors, download
policies and custom transports. The `Parser` API can also parse supplied HTML
without making network requests.

## Limits

- Recognized browser checks receive one compatibility retry. Persistent
  challenges return `browser_verification_required`; there is no CAPTCHA solver.
- Slow-route download retries require an explicit `origin:` on `Downloader`.
- Native transport requires public HTTPS, validates DNS/TLS and confines redirects
  and session cookies to the exact host. Ambient proxies require a custom transport.
- Default bounds: 1 MiB metadata pages, 50 search results, 20 record links;
  downloads allow 128 MiB transferred, 512 MiB expanded and 60 seconds.
- No member API, browser-cookie import, automatic pagination, mirror switching,
  resumable downloads or comic-library import.
- Metadata and file validation do not establish edition identity or permission to
  download. Do not log signed download URLs or credentials.

## Development

See [CONTRIBUTING.md](CONTRIBUTING.md) for tests and development tools.

## License

MIT. See [LICENSE](LICENSE) and [NOTICE](NOTICE) for attribution.
