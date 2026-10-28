# annas-archive.cr

Experimental native Crystal library for Anna’s Archive metadata and verified
file downloads. **Experimental preview: live service availability and file acquisition are
not verified.** No CLI, Python, browser runtime or account is used by this shard.

The current implementation provides bounded search/record parsing and a client
with injectable transport, accessible landing-page resolution, and a bounded
streaming file downloader with native HTTPS transport and one-shot compatibility
retries for recognized challenges. Unresolved protected pages stop with an error. Links from record pages are metadata, not validated
permission or download authority. This is an unofficial HTML interface, not an
Anna’s Archive supported search API. Layout changes can break it.

## Installation

Requires Crystal 1.20+, libxml2 and OpenSSL/CA certificates through the Crystal
standard library. There are no third-party shard dependencies. Native atomic file
publication currently targets POSIX systems. Tested on Crystal 1.20.2/Linux.

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
errors. Parsing itself never retries or changes signed query values.

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

`Client.new(origin, fetch, delay_seconds: 30, clock: ..., challenge_retries: true)` accepts a verified HTTPS
origin and `Proc(String, Response)`. `Response` contains HTTP `status`, body and
optional integer `retry_after` seconds. A production transport must enforce exact
host/DNS/redirect policies, TLS validation, body limits and deadlines **before**
returning a response; the parser’s size check cannot bound an already buffered
network response. Translate and bound HTTP `Retry-After` dates/seconds in that
transport. Do not forward cookies/credentials to other hosts or follow unvalidated
links. `NativeHTTPTransport#page` provides this bounded metadata transport;
custom transports remain responsible for enforcing the same policy.

`search(query, language: nil, format: nil, languages: [], formats: [], content: [],
page: nil, sort: nil, limit: nil)` fetches one `/search` page (at most one challenge retry). Scalar arguments remain
compatible; plural filters emit repeated `lang`/`ext` parameters. `content`, explicit
positive `page` and known sort modes are supported. No additional pages are fetched
automatically. `limit` truncates locally (1–50), matching CLI local result limiting;
it is never sent as a server parameter. Query size remains at most 512 bytes and filter lists at most 20
values. Bibliographic format filters include PDF/EPUB and the comic archive formats;
applications must still reject formats they cannot import. `detail(md5)` fetches one
`/md5/<hash>` page. `resolve(url)` fetches and parses a same-origin
`/slow_download/<md5>/<number>/<number>` landing page. Signed query strings are
preserved; caller-supplied encoded path alternatives and other origins are rejected before HTTP.
It returns `Resolution`; pass its URL to `Downloader` after any required wait. The metadata client never automatically paginates, sleeps, switches
mirrors, imports browser cookies or executes scripts. File streaming is a separate
`Downloader` API, not an implicit effect of search/record parsing. There are no search caches.

Each client serializes requests and enforces a local minimum interval (30 seconds
by default, configurable from 1–3600). This is a client policy, **not** a verified
upstream rate allowance. HTTP 429 extends that cooldown using bounded supplied
`retry_after` seconds; callers own any later scheduling. A request is charged even
if its transport fails. Do not recreate clients to evade cooldowns.

## One-shot challenge compatibility (0.3.0)

Enabled by default for `Client`; set `challenge_retries: false` to opt out.
Only the existing recognized challenge markers trigger a retry. Search/record
GETs append literal `check=%31` to the original raw query (including repeated
filters). `Client.resolve` instead replaces only the original same-origin
`/slow_download/<lowercase-md5>/<number>/<number>[/]` raw prefix with
`/slow%5Fdownload/`, preserving the complete signed query byte-for-byte.
There is no query reserialization, general error retry, solver, browser,
proxy bypass, mirror discovery or mirror switching. A second challenge returns
`browser_verification_required`; plain 401/403/429, network failures and
ordinary error pages never trigger a compatibility retry.

For direct slow-route file transfers, configure the mirror explicitly:

```crystal
# Share this transport between Client and Downloader to retain the same session.
transport = AnnasArchive::NativeHTTPTransport.new
downloader = AnnasArchive::Downloader.new(transport,
  origin: "https://annas-archive.gl", challenge_retries: true)
```

`Downloader.new(transport, policy, origin: nil, challenge_retries: true)`
preserves existing constructors. **Without origin, no download URL is rewritten.**
Even with origin, external hosts, already encoded or nonmatching raw paths are
never rewritten. Each download retry shares the original transfer deadline and
cancellation context; no challenge bytes enter the partial file or hash state.
Challenge/error HTML inspection is bounded to 1 MiB. Normal validation, atomic
no-overwrite publication and partial cleanup remain mandatory.

The one immediate retry belongs to the same serialized metadata operation;
there is no sleep. Its request is charged to the client's minimum interval too.
429 and typed transport rate-limit errors on either request retain cooldowns;
callers schedule subsequent operations. Each metadata transport call retains its
normal page size/deadline policy (native default: 1 MiB / 30 seconds per request).
Injected transports must retain the same policy and session across calls.

The shared native transport retains response cookies in memory, including on
challenge responses and permitted redirects. The conservative RFC6265 subset
supports default/path-boundary matching, Secure, Expires, Max-Age (including
deletion), replacement and secure cookie prefixes. Domain cookies are accepted
only for the response's exact host and never sent to subdomains/other hosts.
At most 32 cookies of 1024 bytes each are retained; malformed, oversized and
excess new cookies are ignored. No browser cookie loading, cookie files,
credentials or cookie logging are added. Redirect/DNS/TLS/proxy policies are
unchanged. This is a session cookie jar, not browser or HTTP connection pooling.

These compatibility behaviors are synthetic/offline verified only. They do not
establish that a live challenge accepts the retry or that native live file
acquisition works. See [challenge evidence](spec/differential/CHALLENGES.md).

## Errors and stability

`AnnasArchive::Error` exposes `code` and nullable `retry_after`; its message is the
closed code, never source HTML, credentials, transport exception text or a URL.

| Code | Meaning |
| --- | --- |
| `invalid_input` | Invalid origin, query, filter or MD5 |
| `browser_verification_required` | Recognized challenge remains after the bounded retry, is outside scope, or retries are disabled |
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

That reference's one-shot query/path encoding retries are implemented natively
(see below); this is not a JS/CAPTCHA solver or live availability claim. Membership/browser-cookie import,
arbitrary cross-origin HTML traversal, comic import and resumable jobs are not
implemented. Ordinary same-host HTTPS redirects are bounded; file streaming,
MD5/SHA-256 and bounded ZIP CRC/EPUB checks are implemented by `Downloader`.

The native implementation adapts the pinned MIT retry behavior; see `NOTICE`.
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


## Standalone verified file downloads (local review)

```crystal
transport = AnnasArchive::NativeHTTPTransport.new
client = AnnasArchive::Client.new("https://annas-archive.gl", ->(url : String) {
  transport.page(url)
})
# Search, inspect a record, choose an ordinary source, and schedule any required
# cooldown/countdown before client.resolve. Plain denied routes are never retried.
# `resolved` is the explicit Resolution from that permitted landing page.
# output_directory must already exist, be caller-owned, and not group/world writable.
# result = AnnasArchive::Downloader.new(transport).download(
#   resolved, File.join(output_directory, "book.epub"), selected.md5, "epub")
```

`Downloader#download(url_or_resolution, destination, expected_md5, format: nil,
cancelled: -> { false }, progress: nil)` performs one file transfer with at most
one scoped challenge retry when configured (see below). MD5 is required
and SHA-256 is computed while streaming. It returns `DownloadedFile` with `path`,
`bytes`, `md5`, `sha256` and `validation`. A countdown produces
`download_wait_required` with `retry_after`; it does not sleep or request a file.

Default `DownloadPolicy` limits are 128 MiB transferred, 60 seconds elapsed,
512 MiB expanded ZIP bytes and 10,000 ZIP entries. Configure these explicitly for
larger authorized files. `format: "epub"` checks ZIP CRCs, the EPUB mimetype and
container entry before publication. ZIP/CBZ/DOCX use ZIP CRC validation; PDF and RAR
use signature checks; no format hint means hash-only validation. These checks do
not establish comic identity, authenticity, rights, or Imported state.

Native transport requires HTTPS, excludes private/reserved/literal-IP targets,
checks every DNS answer and pins the revalidated address while preserving TLS
hostname verification/SNI. Redirects stay on the exact initial host and stop after
three hops. No cookies or credentials are loaded from disk/browser; bounded
same-host response cookies are retained in memory by the shared native transport. Error/redirect bodies are not
drained indefinitely; metadata bodies and headers are bounded. HTTP 429 retains a
per-host Retry-After cooldown; reuse the downloader rather than recreating it to
evade that cooldown. The conservative address filter follows the
[IANA IPv6 special-purpose registry](https://www.iana.org/assignments/iana-ipv6-special-registry/). Blocking DNS is isolated in at most one outstanding
native worker; timeout/cancellation returns promptly and further resolution fails
busy until that worker finishes. Network sockets close on deadline/cancellation;
ZIP validation checks the deadline between bounded chunks. OS filesystem calls
such as fsync cannot be forcibly preempted by this library.

The native transport refuses ambient proxy configuration with
`download_proxy_transport_required`; it never silently bypasses an embedding
network policy. An authorized proxy environment must supply a `StreamTransport`
that enforces its proxy, URL, public-address, redirect, byte and deadline policy.
Injected `open` callbacks must stream within their lifetime and honor
`TransferContext`; they cannot return an unbounded background reader.

Output uses a private 0600 partial in a caller-controlled directory, opened via
an anchored descriptor. Verified bytes are published with a no-overwrite atomic
hard link. Cancellation, truncation, mismatch and errors remove the partial.
Existing files and symlinks are never replaced. `download_publication_uncertain`
means verified final bytes may exist after a sync/namespace failure; inspect that
file rather than blindly retrying. Process termination or filesystem failure can leave a private partial;
partials are never automatically resumed or treated as complete files.

Run the complete offline consumer example with a private empty output directory:

```sh
crystal run examples/standalone_fixture.cr -- /tmp/anna-offline-output
python3 spec/differential/compare_downloads.py \
  --reference /path/to/pinned/annas-archive-cli \
  --python /tmp/anna-parity-env/bin/python
```

No live Anna request is made by either command. The full workflow fixture uses
identical synthetic EPUB bytes for both clients, including search, record,
countdown, landing control, ordinary redirect, transfer and hash/file validation.
See `spec/differential/download-results.json` for success and failure evidence.
The ordinary download comparison keeps the reference's outer retry method disabled.
The separate challenge comparison executes the pinned retry methods against offline
fixtures only; see `spec/differential/challenge-results.json`.
