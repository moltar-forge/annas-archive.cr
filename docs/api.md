# API reference

[Back to README](../README.md)

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
`Entry` has `md5`, `title`, raw `summary`, and nullable `language`, `format`,
`author`, `publisher`, `size`, `cover_url` and `url` fields.
It does not infer series, issue, publication year, edition, collection contents or
copyright/license status from bibliographic text.

`Parser.detail(html, md5, origin)` returns `Detail`, containing `entry`, `description` and
`Array(Link)`. Each link has `url`, `kind` and `label` fields. A link’s `kind` is
`browser`, `member` or `external`. `Link.scheme` and `Link.fetchable?` separate
informational HTTP/magnet/ipfs metadata from potential HTTPS downloads.
Neither these labels nor an HTTPS scheme prove a URL is safe to fetch. Raw
metadata and signed link URLs are private/untrusted; sanitize application output
and never log locators or attach them to error messages.

`Parser.resolve(html, page_url)` reads an explicit download control or displayed
`js-partner-countdown` from an ordinary accessible landing page. It returns
`Resolution` with either `url` or `wait_seconds`; it performs no request or wait.
The caller must validate every returned URL against its own transport policy and
schedule any countdown. Unknown controls, login forms and challenges stop with
errors. Parsing itself never retries or changes signed query values.

## Client and transports

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
page: nil, sort: nil, limit: nil)` fetches one `/search` page, with at most one
challenge retry. Plural filters emit repeated `lang`/`ext` parameters. `content`, explicit
positive `page` and known sort modes are supported. No additional pages are fetched
automatically. `limit` truncates locally (1–50) and is never sent as a server
parameter. Query size is at most 512 bytes and filter lists at most 20
values. Bibliographic format filters include PDF/EPUB and the comic archive formats;
applications must still reject formats they cannot import. `detail(md5)` fetches one
`/md5/<hash>` page. `resolve(url)` fetches and parses a same-origin
`/slow_download/<md5>/<number>/<number>` landing page. Signed query strings are
preserved; caller-supplied encoded path alternatives and other origins are rejected before HTTP.
It returns `Resolution`; pass its URL to `Downloader` after any required wait. The metadata client never automatically paginates, sleeps, switches
mirrors or executes scripts. CookieSession can explicitly import a caller-provided
Netscape export, then be injected into the shared native transport. File streaming is a separate
`Downloader` API, not an implicit effect of search/record parsing. There are no search caches.

Each client serializes requests and enforces a local minimum interval (30 seconds
by default, configurable from 1–3600). This is a client policy, **not** a verified
upstream rate allowance. HTTP 429 extends that cooldown using bounded supplied
`retry_after` seconds; callers own any later scheduling. A request is charged even
if its transport fails. Do not recreate clients to evade cooldowns.

## Mirror health

```crystal
health = client.healthcheck
if health.status.rate_limit?
  # Schedule a later operation using health.retry_after; never recreate to evade it.
end
```

Available on both Client and Acquisition. The fixed probe is `search("comic",
formats: ["cbz", "cbr"], limit: 1)`: one bounded metadata page, at most one
existing challenge retry, local truncation to one record. It uses the configured
mirror and persistent session/pacing/cooldowns; no discovery or mirror switching.
Valid parsed results **or explicit empty-search text** mean Working. A successful
search does not prove authentication, membership, file availability or download
readiness. It does not download a file.

HealthCheck fields are `status : HealthStatus`, nullable `error_code : String?`
and nullable `retry_after : Int32?` (seconds). Enum states:

- Working: parsed search, including a valid empty search; no error fields.
- Challenge: `browser_verification_required` after the configured retry policy.
- RateLimit: `rate_limited` from local pacing or server cooldown; retains retry_after.
- Network: `network_error`, `download_network_error`, `download_timeout`,
  `download_dns_failed` or `download_resolver_busy`, including a total deadline
  spent in local pacing.
- Layout: `unrecognized_page`, `malformed_response`, `page_too_large` or `result_limit`.
- Error: other typed failures, including auth/access denial, unsafe transport
  policy, cancellation and clock faults. The original closed error code remains.

The result contains no origin, source locator, HTML, cookie or exception message.
Only typed AnnasArchive::Error failures are classified. Metadata fetch IO::Error
is closed to network_error; arbitrary programmer exceptions from injected
callbacks propagate, rather than being mislabeled as network health. Custom
transports must translate operational failures to IO::Error or existing closed
AnnasArchive::Error codes, never embed private data in error codes. Do not log
arbitrary callback exception messages. This narrows the former blanket metadata
exception rescue; the file-download error/publication contract is unchanged.

Acquisition.healthcheck(cancelled: -> { false }) shares its normal total operation
deadline, bounded cancellable pacing and native network policy. Each probe is an
operation on the same coordinator, not a fresh session. Client.healthcheck uses
Client's non-sleeping minimum interval and the injected transport's page deadline.

## Challenge retries

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
requires an explicit origin for slow-route retries. Without an origin, no download
URL is rewritten.
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
excess new response cookies are ignored. Optional Netscape imports are explicit,
scoped and atomic (see below); no browser profile discovery or cookie logging occurs. Redirect/DNS/TLS/proxy policies are
unchanged. This is a session cookie jar, not browser or HTTP connection pooling.

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
| `network_error` | Injected metadata transport raised IO::Error (programmer faults propagate) |
| `unavailable` | Other non-200 HTTP response |
| `unrecognized_page` | Layout not recognized; never counted as no results |
| `unsupported_resolution` | No recognized explicit file control or countdown |
| `malformed_response` | Invalid encoding or invalid parsed fields |
| `page_too_large` / `result_limit` | Bounded parser limits exceeded |

Only explicit empty-search text yields an empty result list. Metadata pages are
limited to 1 MiB; searches to 50 distinct records; record links to 128 unique valid
URLs, with at most 256 source anchors, 4096 bytes per URL and 1024 bytes per label.
Exceeding a bound raises `result_limit`, without truncation. Links retain document
order and signed query bytes; duplicates and filtered URLs still count toward the
source-anchor bound, but not the unique-link bound. Relative and verified same-origin
`/md5/<hash>` search links are interpreted as identifiers; their canonical record
URLs are reconstructed and foreign origins are ignored. Hidden result comments are
read only inside `js-scroll-hidden` containers. No external entities are fetched.
Fields remain bibliographic hints; applications must separately match and validate
actual archives before considering an issue acquired or imported.

## File downloads

Use a `Resolution` returned by `Client.resolve` after scheduling any required
countdown. Share the same native transport with the client to retain cookies.

To download a selected file URL directly (not an unresolved landing page):

```crystal
require "annas_archive"

origin, file_url, expected_md5, destination = ARGV
transport = AnnasArchive::NativeHTTPTransport.new
downloader = AnnasArchive::Downloader.new(transport, origin: origin)
file = downloader.download(file_url, destination, expected_md5, "epub")
puts file.sha256
```

`Downloader#download(url_or_resolution, destination, expected_md5, format: nil,
cancelled: -> { false }, progress: nil)` performs one file transfer with at most
one scoped challenge retry when configured (see [Challenge retries](#challenge-retries)).
MD5 is required
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
three hops. No cookies are loaded implicitly; an explicit CookieSession import may
read a caller-selected Netscape file. Bounded same-host response cookies are
retained in memory by the shared native transport. Error/redirect bodies are not
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

---

# Verified acquisition

`Acquisition.new(origin, transport = NativeHTTPTransport.new)`
composes a persistent Client and Downloader on one transport/cookie session.
Use only with content you are authorized to acquire. No live-service reliability
or full Python parity is claimed.

```crystal
require "annas_archive"

a = AnnasArchive::Acquisition.new("https://your-configured-mirror.example")
a.record("/md5/0123456789abcdef0123456789abcdef", "/private/existing/book.epub",
  format: "epub", max_wait: 300)
a.download("https://public-file-host.example/signed-url", "/private/existing/file",
  expected_md5: "0123456789abcdef0123456789abcdef")
```

## Comic integration

Use Acquisition.search(query, **filters) and Acquisition.detail(value) to keep
metadata, health and record/download operations on one persistent transport,
clock, pacing scheduler and cookie jar. Search filters and return types are the
same as Client's; each metadata call has the configured total operation timeout.
Calls serialize and retain cooldowns. No caller-owned landing/wait loop is needed.

The embedding application selects a search record and may display Detail.links
in retained order. Pass source: N to record for an explicit one-based source, or
omit it for the first non-member fetchable HTTPS source. record refetches detail
under the same policy before selection (no cache or file preflight); indices are
stable for that page, not guaranteed across upstream page changes. The caller
must handle terminal failures, not silently mark an issue acquired or imported.

Always pass a supported comic format hint (cbz/cbr) when format validation is
needed: no hint remains hash_only. CBZ validation checks ZIP structure/CRCs, not
whether entries are images or the requested issue. CBR validation is RAR signature
plus mandatory MD5, not a full RAR archive/decompression/CRC check. Mylar4 owns
issue/edition identity, image/import checks and imported-state transitions.

Acquisition defaults remain 128 MiB transferred, 512 MiB expanded, 10,000 ZIP
entries and 300 seconds **total per operation**, including pacing, countdown,
transfer and verification. A large comic/collection or slow connection can exceed
these; failure does not imply a corrupt or unavailable issue. Configure a reviewed
DownloadPolicy explicitly, for example:

```crystal
policy = AnnasArchive::DownloadPolicy.new(max_bytes: 268_435_456_i64,
  max_uncompressed_bytes: 1_073_741_824_i64, max_entries: 20_000, timeout: 300.seconds)
client = AnnasArchive::Acquisition.new(origin, AnnasArchive::NativeHTTPTransport.new, policy)
```

Byte/expanded limits may be 1..2 GiB, entries 1..65,535 and timeout positive up to
300 seconds. max_wait cannot extend that deadline. Defaults are not automatically
weakened for comics. Native public HTTPS/DNS/TLS, signed-query/session bounds,
atomic no-overwrite publication and mandatory expected MD5 remain enforced.
For an already selected direct URL, use client.download(url, expected_md5: md5,
format: "cbz", directory: private_directory); it does not select a record/source.

[Runnable offline workflow](../examples/comic_workflow_fixture.cr) uses synthetic
metadata and a generated ZIP; it is not evidence of live-service reliability.

## Inputs and selection

Client.detail and Acquisition.record accept trimmed, case-insensitive bare MD5,
relative /md5/<hash> paths (optional trailing slash), or HTTP(S) record URLs.
Only the identifier is used: metadata always comes from the configured HTTPS
origin, never the supplied origin. Credential-bearing URLs are rejected.
A supplied expected_md5 must match a record identifier. Direct downloads always
require expected_md5 (the same identifier forms are accepted).

Record acquisition defaults to the first non-member HTTPS link in parser order.
source: N selects a stable one-based index in Detail.links, including member
links; invalid indices, no regular source, and checksum mismatch are terminal.
No automatic mirror/source fallback occurs. HTTP/magnet/ipfs links remain in the
record list and count toward its bounds; indices describe that full retained list.
Selecting a non-fetchable source returns `unsupported_source` without fetching it.

Output may be explicit or omitted in Acquisition. An explicit path wins over
response naming and directory; omitted output uses `directory:` (default `.`).
Acquisition prepares missing parents privately; low-level Downloader explicit
output retains its original existing-parent default. Publication remains anchored,
atomic and no-overwrite;
partial files are removed on failure. format enables existing format/ZIP-CRC
validation; without it the result is hash_only. progress receives cumulative
bytes, not chunk deltas. A signed file is consumed once, never prefetched.

## Scheduling, budgets, errors

- One operation owns one TransferContext, created before metadata. Default total
  timeout is 300 seconds; DownloadPolicy.timeout must be positive and at most
  five minutes. It includes metadata, local pacing, countdowns, traversal,
  transfer, verification and pre-publication checks; no stage resets it.
- The additional max_wait (default 300, negative invalid) is an elapsed monotonic
  allowance starting at acquisition of the chosen URL, after record metadata.
  Network/pacing time during traversal consumes this allowance too. Countdown
  delay is seconds+1 and must fit entirely. Zero/over-budget returns
  download_wait_required with retry_after containing the parsed seconds.
- Only exact configured-origin /slow_download/<lowercase-md5>/<n>/<n> (and its
  one-shot encoded retry) countdowns may sleep. External countdowns never sleep.
  wait_progress receives per-second remaining values then final 0 on successful
  wait completion; interrupted waits need not emit 0.
- Six attempts maximum; only countdowns start another attempt. A fourth ordinary
  landing response cannot transition again (download_landing_limit). Cycles,
  login, unknown/oversized pages and persistent challenges fail closed. Only one
  same-origin slow challenge rewrite is allowed for a transfer; metadata retains
  its existing one-shot check=%31 retry. No generic retries exist.
- A persistent local minimum interval (30 seconds by default, configurable
  1..3600) spaces configured-origin top-level opens, including compatibility
  retries (redirect exchanges within an open keep native redirect semantics).
  Scheduling sleeps in at-most-one-second slices, bounded by the total deadline.
  Cancellation is checked before/after sleeps, callbacks, requests, and chunks.
  Injected monotonic clock/sleeper must advance consistently; callbacks must not
  block indefinitely. A nonadvancing sleeper fails with download_clock_stalled.
  Calls on one coordinator are serialized; lock queue time
  precedes operation start and is not charged to the operation deadline.
- Server 429 is terminal, never automatically retried/slept. Retry-After cooldowns
  persist across operations and are distinct from local pacing. Reuse the same
  coordinator instead of constructing one to bypass cooldowns.
- At most 64 top-level transport opens per operation. Native transport has at
  most six exchanges per open (default four), so even redirects remain globally
  bounded (384 exchanges maximum, default 256). HTML stays bounded to 1 MiB;
  file, archive expansion, DNS, TLS and deadline limits remain enforced.

Explicit HTML download controls may select another public HTTPS host, but HTTP
redirects are still exact-host only. Every target goes through PublicHTTPS and
the native public-DNS/TLS checks. HTTP/private addresses, ambient proxies, and
network-policy bypasses remain prohibited. Query bytes are not decoded/rebuilt;
relative controls are resolved without parsing signed queries into parameters.
Injected transports must preserve the same network policy and context checks.

## Browser-session and output options

```crystal
jar = AnnasArchive::CookieSession.new
# Caller-provided export only; no automatic browser/profile access.
jar.import_netscape_file("/private/caller-selected-cookies.txt", origin)
# Or jar.import_netscape(text_or_io, origin).
a = AnnasArchive::Acquisition.new(origin, cookies: jar, user_agent: "MyBrowser/1.0")
a.record(md5, directory: "/private/downloads", format: "epub")
a.download(file_url, expected_md5: md5, directory: "/private/downloads")
```

Imports authorize one HTTPS origin. Host-only exports must match exactly;
Domain exports may match its parent suffix but are stored only for that exact
host, never its siblings/subdomains. Paths, Secure, expiry (0 means session),
#HttpOnly_, cookie prefixes and replacement/deletion are respected. The jar
is not broadened to the export's Domain. Unrelated cookies are not imported.
A malformed import or capacity overflow leaves the entire existing jar unchanged.
Inputs are at most 64 KiB, 256 lines, 2048 bytes/line; cookies are at most 1024
bytes including conservative host/path overhead, 32 per jar across all hosts.
Fields use printable ASCII cookie syntax (tabs delimit fields); CRLF exports
are accepted. Errors are closed cookie_import_invalid/too_large/capacity/unreadable
codes and never include input, paths or cookie values. IO implementations are
trusted synchronous inputs, not background/unbounded network readers.

User-Agent is 1..512 printable ASCII bytes, nonblank; controls/CRLF are rejected.
Default remains annas-archive.cr/VERSION. To configure metadata alone, use
NativeHTTPTransport.new(cookies: jar, user_agent: agent) and its page method;
share that instance for Client/Downloader. No subclass is needed for configuration.

Automatic names come only from the actual terminal file response: UTF-8
filename* takes precedence over ordinary quoted/unquoted filename, then effective
post-redirect URL basename. Invalid UTF-8 bytes are replaced, percent-decoding is
single-pass, encoded/backslash separators are removed, controls/unsafe Windows
characters and reserved names are neutralized, and UTF-8 names are capped to
180 bytes. Empty names become download.bin. Content-Disposition/name input is
bounded to 8192 bytes. Explicit paths are not renamed and ignore those headers.

Automatic preparation walks from / with no-follow descriptor-relative opens,
rejecting symlink ancestry and group/world-writable directories (even /tmp).
Ancestry must be root/caller-owned, the final directory caller-owned, and new
0700 descendants are created only beneath caller-owned non-shared parents.
At most 128 components/4096 input bytes are allowed. Inode/permission checks run
before and after anchored no-overwrite publication. Existing files and symlinks,
including targets appearing mid-transfer, are never overwritten. Failed transfers
remove their partial; newly created empty directories are not rolled back.
A failure after publication remains download_publication_uncertain, not an
invitation to blindly retry. Low-level Downloader(url, explicit_path, md5) still
requires an existing safe caller-owned parent by default; only opting into
prepare_parents (or nil destination plus output_directory) adds preparation.

## Comparison and remaining limitations

See [library comparison](library-parity.md) for source mapping, test evidence and
explicit remaining differences. Executable CLI and proxy parity are excluded;
checksum-optional downloads remain deferred, not an unchecked mode. This is not
full Python parity or a Mylar4 integration/deployment.
