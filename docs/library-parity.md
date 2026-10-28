# Native library / pinned Python comparison

Scope: Python 0.2.0rc4, upstream revision
`001ab3250e9cd829e7225b6385e3fb8aac999090`. Source mapping below is to
src/anna/client.py (P), parsing.py (PP), and cli.py (CLI) at that revision.
The target is useful reusable comic acquisition for Mylar4, not Python-shaped
names or executable CLI/proxy equivalence; CLI and proxy parity are excluded.
This describes library workflows, not live-service reliability. Safeguards are
genuine restrictions versus Python, not self-approved exceptions that establish
full parity.

| Python capability / source | Native public API and current evidence |
| --- | --- |
| Search/record parsing, legacy/current/deferred cards (PP53–253) | Parser.search/detail and Client.search/detail return Entry/Detail/Link. Existing metadata specs cover ordering, dedupe, bounds and challenge/empty-layout classification. Nullable fields and field names differ (Entry.summary versus Python Book.metadata; Detail nests entry). |
| Fixed mirror search probe (doctor concept, not CLI equivalence) | Client.healthcheck and Acquisition.healthcheck return HealthCheck/HealthStatus with closed error code/retry_after. comic_workflow_spec covers explicit-empty success, layout/challenge/HTTP/IO failures, shared cookies and persistent actionable cooldowns. No authentication/download-ready claim. |
| Trimmed MD5, record path/HTTP(S) URL (PP39–50) | Client.record_id/detail and Acquisition.record normalize the hash and fetch only configured origin. acquisition_spec proves supplied origin is never fetched. |
| Repeated search filters, page/sort (P172–182) | Client.search has typed singular/plural language/format, content, page, sort and local limit. One page only; no arbitrary keyword forwarding. Query512 bytes, lists20, results50, known filter values; not Python's unrestricted kwargs surface. |
| Source links and CLI one-based selection/default non-fast (PP200–213; CLI328–360) | Link keeps url/kind/label and adds scheme/fetchable?. HTTP/magnet/ipfs are informational; Acquisition.record selects the first non-member fetchable HTTPS or explicit stable index, no fallback. informational_links_spec covers metadata/capabilities/indices. Kind member/browser/external corresponds to fast/slow/external; this is not a member API. |
| Landing traversal/countdown notifications/challenge retry (P87–111,184–272) | Acquisition owns bounded traversal, six attempts, seconds+1 waits/final0, one-shot challenge compatibility, persistent pacing/cooldowns and one total context. acquisition_spec covers deterministic fake-clock success/failures; defaults and elapsed-budget semantics are in api.md. |
| Netscape import, session expiry0 and custom UA (P119–149) | CookieSession.import_netscape(text_or_io, origin), import_netscape_file and NativeHTTPTransport(cookies:, user_agent:), also Acquisition factory options. browser_session_spec uses only synthetic exports and native exchange seams. Imports are atomic, bounded and exact-host narrowed, not full browser cookiejar behavior. No profile discovery or script/CAPTCHA execution. |
| Response filename or explicit path, directory creation (P50–69,279–287) | Acquisition.record/download allow omitted destination with directory:. OutputNaming uses filename*/filename/effective URL with bounded sanitization. output_spec covers UTF8/traversal/races/no-overwrite/cleanup; directory preparation is deliberately stricter (no symlink/shared ancestry). No preflight or duplicate file fetch. |
| Transfer/checksum/progress (P288–320) | DownloadedFile includes absolute path/bytes/MD5 plus SHA256 and validation. progress is cumulative, not Python chunk deltas; subtract previous total for deltas. Format hints enable ZIP CRC/EPUB structure/signature checks. Native streaming and atomic anchored publication remain mandatory. |

## Genuine restrictions and unimplemented surfaces

- Checksum-optional behavior is deferred: Python can omit expected MD5; native
  direct downloads require it, while record acquisition infers it and rejects
  mismatches. There is no unchecked mode.
- Python HTTP(S)/httpx redirects and ambient proxy behavior are not replicated:
  native fetching is public HTTPS with DNS/TLS verification, exact-host HTTP
  redirects, explicit proxy-transport requirement and signed-query preservation.
  Explicit HTML controls may choose another validated public HTTPS host. A
  fetchable? value is a URL capability, not DNS, integrity, identity or rights proof.
- Credential-bearing and fragment-bearing source URLs remain filtered from
  metadata, unlike Python's broader listing. This does not grant network access
  to retained informational schemes.
- Native resource/time/input/result bounds, typed filters, local request pacing,
  total deadline and exact-host cookie narrowing differ from Python. Cookie imports
  require one explicit authorized origin, bounded printable ASCII fields and 32-slot
  capacity; response Domain cookies still cannot broaden to parent domains.
- Automatic preparation refuses unsafe ancestry, including shared /tmp and symlink
  paths. Filesystem fsync and blocking caller callbacks/IO cannot be forcibly
  preempted. Output naming/preparation does not bypass publication/integrity checks.
- CBZ receives ZIP structural/CRC validation; CBR only RAR signature plus MD5,
  not full archive integrity. Mylar4 owns issue identity/import, not this client.
- No executable search/info/links/download/doctor CLI, JSON command schemas, exit
  codes, installers or terminal progress UI is supplied. These are not represented
  as library parity. No automatic pagination, mirror failover/discovery, member-key
  API, resume/range mode, or CAPTCHA solver is claimed or invented from Python.

## Evidence boundaries

Acquisition.search/detail close the shared-coordinator metadata usability gap
without renaming Client APIs. comic_workflow_spec exercises CBZ/CBR search through
caller selection/detail/source listing into public record acquisition, default/
explicit sources, signed countdown/control traversal, terminal file-only fetch,
CRC/hash cleanup and honest CBR signature boundaries. Existing acquisition tests
retain cancellation/deadline/progress/network security coverage.

New native offline tests exercise public workflows and native transport seams;
fixture responses replace socket exchange, so no live Anna requests occur.
Historical spec/differential reports are preserved as historical comparisons;
they are not proof of new orchestration/import/naming cases and were not rerun
as part of this implementation. No new Python match count or full-parity claim is
made. See the run's lane evidence / parent review for exact commands and counts.
