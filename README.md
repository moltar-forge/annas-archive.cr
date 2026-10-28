# annas-archive.cr

Experimental native Crystal library for parsing Anna’s Archive search and record
HTML. **Experimental preview: live service availability and file acquisition are
not verified.** No CLI, Python, browser runtime or account is used by this shard.

The current implementation provides bounded search/record parsing and a client
with an injected transport, plus parsing of accessible download landing pages.
It does **not** fetch book files or resolve protected
download landing pages. Links from record pages are metadata, not validated
permission or download authority. This is an unofficial HTML interface, not an
Anna’s Archive supported search API. Layout changes can break it.

## Installation

Requires Crystal 1.20+ and libxml2, used by Crystal’s standard XML library. There
are no third-party shard dependencies. Tested on Crystal 1.20.2/Linux.

Add the dependency to your application and pin a reviewed revision for production:

```yaml
dependencies:
  annas_archive:
    github: moltar-forge/annas-archive.cr
    branch: main
```

Run `shards install`, then `require "annas_archive"`.

## Parser API

```crystal
require "annas_archive"

html = <<-HTML
<a href="/md5/11111111111111111111111111111111">
  <div class="text-gray-500">English [en], CBZ, 12 MB</div>
  <h3>Example Comic 001 (2020)</h3>
</a>
HTML

entries = AnnasArchive::Parser.search(html)
puts entries.first.title
puts entries.first.language # en
puts entries.first.format   # cbz
```

`Parser.search(String)` returns `Array(Entry)` and deduplicates record MD5s.
`Entry` has `md5`, `title`, nullable `language`/`format`, and raw `summary` fields.
It does not infer series, issue, publication year, edition, collection contents or
copyright/license status from bibliographic text.

`Parser.detail(html, md5, origin)` returns `Detail`, containing `entry` and
`Array(Link)`. A link’s `kind` is `browser`, `member` or `external`.
Neither these labels nor an HTTPS scheme prove a URL is safe to fetch. Raw
metadata and signed link URLs are private/untrusted; sanitize application output
and never log locators or attach them to error messages.

`Parser.resolve(html, page_url)` reads an explicit download control or displayed
`js-partner-countdown` from an ordinary accessible landing page. It returns
`Resolution` with either `url` or `wait_seconds`; it performs no request or wait.
The caller must validate every returned URL against its own transport policy and
schedule any countdown. Unknown controls, login forms and challenges stop with
errors. Signed query values are preserved without encoding workarounds.

## Client and transport boundary

```crystal
require "annas_archive"

# Synthetic example: this transport performs no network requests.
transport = ->(url : String) {
  AnnasArchive::Response.new(200, "<p>No files found</p>")
}
client = AnnasArchive::Client.new("https://catalog.example.invalid", transport)
puts client.search("Example Comic 001 (2020)", language: "en", format: "cbz").size
```

`Client.new(origin, fetch, delay_seconds: 30, clock: ...)` accepts a verified HTTPS
origin and `Proc(String, Response)`. `Response` contains HTTP `status`, body and
optional integer `retry_after` seconds. A production transport must enforce exact
host/DNS/redirect policies, TLS validation, body limits and deadlines **before**
returning a response; the parser’s size check cannot bound an already buffered
network response. Translate and bound HTTP `Retry-After` dates/seconds in that
transport. Do not forward cookies/credentials to other hosts or follow unvalidated
links. No general network transport is included in this prototype.

`search(query, language: nil, format: nil, languages: [], formats: [], content: [],
page: nil, sort: nil)` fetches exactly one `/search` page. Scalar arguments remain
compatible; plural filters emit repeated `lang`/`ext` parameters. `content`, explicit
positive `page` and known sort modes are supported. No additional pages are fetched
automatically. Query size remains at most 512 bytes and filter lists at most 20
values. Bibliographic format filters include PDF/EPUB and the comic archive formats;
applications must still reject formats they cannot import. `detail(md5)` fetches one
`/md5/<hash>` page. `resolve(url)` fetches and parses one ordinary same-origin
`/slow_download/<md5>/<number>/<number>` landing page. Signed query strings are
preserved; encoded path alternatives and other origins are rejected before HTTP.
It returns `Resolution`, never file bytes. The client never automatically paginates, retries,
sleeps, switches mirrors,
imports cookies, executes scripts or downloads files. There are no search caches.

Each client serializes requests and enforces a local minimum interval (30 seconds
by default, configurable from 1–3600). This is a client policy, **not** a verified
upstream rate allowance. HTTP 429 extends that cooldown using bounded supplied
`retry_after` seconds; callers own any later scheduling. A request is charged even
if its transport fails. Do not recreate clients to evade cooldowns.

## Errors and stability

`AnnasArchive::Error` exposes `code` and nullable `retry_after`; its message is the
closed code, never source HTML, credentials, transport exception text or a URL.

| Code | Meaning |
| --- | --- |
| `invalid_input` | Invalid origin, query, filter or MD5 |
| `browser_verification_required` | Recognized challenge; no retry or bypass |
| `authentication_required` | HTTP 401 |
| `access_denied` | HTTP 403 without a recognized challenge |
| `rate_limited` | HTTP 429 or local cooldown |
| `network_error` | Injected transport raised an exception |
| `unavailable` | Other non-200 HTTP response |
| `unrecognized_page` | Layout not recognized; never counted as no results |
| `unsupported_resolution` | No recognized explicit file control or countdown |
| `malformed_response` | Invalid encoding or invalid parsed fields |
| `page_too_large` / `result_limit` | Bounded parser limits exceeded |

Only explicit empty-search text yields an empty result list. Metadata pages are
limited to 1 MiB; searches to 50 distinct records; record links to 20. Relative and verified same-origin
`/md5/<hash>` search links are interpreted as identifiers; their canonical record
URLs are reconstructed and foreign origins are ignored. Hidden result comments are
read only inside `js-scroll-hidden` containers. No external entities are fetched.
Fields remain bibliographic hints; applications must separately match and validate
actual archives before considering an issue acquired or imported.

## Interface evidence and exclusions

The [official FAQ](https://annas-archive.gl/faq#api) documents a stable member API
for download URLs and recommends bulk databases for custom search. This library
does not implement that API or claim a supported hosted search contract.

The identified reference is [meurz/annas-archive-cli](https://github.com/meurz/annas-archive-cli)
at `001ab3250e9cd829e7225b6385e3fb8aac999090`. We inspected its search/record
parsing, HTTP client, error types, MIT license and live-verification notes. Its
search uses `/search` HTML; records use `/md5/<hash>`. Its free-source downloader
handles landing pages/countdowns and verifies catalog MD5s. These behaviors do
not establish a stable service contract or guaranteed comic metadata quality.

That reference also changes query/path encoding after challenges. **Those retries
are excluded here.** Protected pages stop with an error. Membership/cookie support,
automatic multi-hop traversal, streamed transfer, MD5 validation,
archive validation/import and resumable jobs are not implemented.

The implementation and synthetic fixtures are independently written; see `NOTICE`.
Four reduced MIT-licensed reference HTML fixtures are included with their license
for reproducible comparisons. No ebooks, account data, private application files
or production configuration are included.

## Verification

```sh
crystal spec
crystal tool format --check src spec
```

Tests are entirely synthetic and offline. They cover the two observed card
layouts, deferred comments, duplicates, unknown/empty/protected pages, record link
classification, parser bounds, query encoding, cooldowns, HTTP failures and input
validation. No live service availability, rate allowance, authentication or file
acquisition is claimed by those tests.


## Offline Python comparison

See [the parity report](spec/differential/README.md) for pins, exact commands,
comparison scope and intentional differences. `Entry` now retains author,
publisher, displayed size, cover and record URLs in addition to the original
identity hints. `Detail.description` and `Link.label` retain source metadata.
Existing constructors and scalar `search` calls remain compatible. Metadata URLs
are hints only; they are never fetched or granted download authority by parsing.
