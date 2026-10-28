# Standalone search and download evidence

This local review extends public shard `ae5274a406365dc5dbd30179c6a7414a57f69bf2`
with a native file downloader. It is not a verified live acquisition claim.
Reference Python source is pinned to `001ab3250e9cd829e7225b6385e3fb8aac999090`,
module version `0.2.0rc4`, with MIT attribution retained in NOTICE.

## Reproduce offline

```sh
python3 spec/differential/compare_downloads.py \
  --reference /path/to/pinned/annas-archive-cli \
  --python /tmp/anna-parity-env/bin/python \
  --output /tmp/anna-download-parity.json
crystal spec
crystal tool format --check src spec examples
crystal run examples/standalone_fixture.cr
```

Use the same isolated pinned Python dependencies as the metadata report. The
Python harness hash-checks four imported reference modules, forbids socket/DNS
entrypoints and injects httpx.MockTransport. Its page method is replaced with the
ordinary one-request implementation. The outer `Client.download` method, which
contains challenge-related URL changes, is disabled. Only inspected ordinary
`Client._download` executes, entirely against fixtures. These guards are not an
OS sandbox. Crystal uses a fixture subclass of NativeHTTPTransport: real URL,
redirect and streaming policy runs, with fake public DNS and no real sockets.

Both clients perform search → selected record → countdown → explicit landing
control → ordinary same-host file redirect → streamed bytes. A scheduling clock
advances without real sleeps. The shared ZIP_STORED EPUB contains only original
synthetic CC0 text. The success case transfers **599 bytes**:

- MD5: `ac20330c40fdf2dfce2d0ea3eddb5632`
- SHA-256: `bb10deee9fb40087ece40165dd4b15fc40c7f4284709f1fcb7fb852f0408516f`
- Native validation: ZIP CRCs, EPUB mimetype and container entry.

[`download-results.json`](download-results.json) retains requests, outcomes,
file existence, bytes and hashes. **8 cases: 7 matches, 1 intentional difference,
0 unexplained mismatches.** Matching cases are success, MD5 mismatch, truncation,
403, 500, interrupted body and cancellation. The corruption case intentionally
uses the correct whole-file MD5 of an archive with a corrupt internal CRC: Python
publishes it before the harness detects invalid CRC; Crystal rejects it before
publication. Raw output preserves that difference rather than normalizing it away.

The 45 Crystal specs additionally exercise byte/expanded-size/entry bounds,
private/special/mixed/rebound DNS, signed queries and redirect loops, output races,
existing files/symlinks, cooldowns, private-part cleanup and uncertain publication.
Local TCP fixtures verify deadline/cancellation during a stalled TLS handshake;
no certificate, secret, external connection or real ebook is used.

`examples/standalone_fixture.cr` is also compiled from a clean path-dependency
consumer using `require "annas_archive"` after standard `shards install`. It runs
five offline requests (the example omits the file redirect), writes the same
599-byte validated EPUB and reports its hashes. The library requires no Python,
external CLI or Mylar dependency. Python is only a differential-test dependency.
A temporary local-source compatibility build also passed all 28 focused Mylar
Anna validation/adapter/PostgreSQL examples. The native POSIX declarations coexist
with the application bindings. Mylar source and its public dependency pin were
not changed.

## Verified live boundary

A separate Toshi task recorded a successful Python search on 2026-10-28 at
16:36:48–16:37:10 UTC: installed version `0.2.0rc4`, `.gl` default origin,
`anna search "Ultimate X-Men 1 2001" --json`, exit 0, 3.64 seconds, 20 JSON records,
11550 stdout bytes, empty stderr. The launcher was `anna.real-0.2.0rc4`.
Request exchanges, retry branches and installed source hashes were not recorded.
This proves that CLI search worked in that context; it does not prove a native
normal-request match or a completed file download. Source inspection shows CLI
page=1, limit=20 applied locally, and no language/format filters by default. Those
ordinary request/default/order behaviors now have matching offline cases.

In this cloud environment, both inspected ordinary Python and public Crystal
metadata clients were tested through the same proxy-preserving curl transport
against one identical public-domain bibliographic query. The proxy rejected HTTPS
CONNECT with HTTP 403 (curl exit 56); no Anna origin status/body was received.
Crystal probe: 2026-10-28 16:20:55 UTC. Python: 16:23:01.951879 UTC. No record,
landing or document requests followed, and no document bytes were downloaded.
That is a cloud proxy restriction, not evidence that Anna or Toshi is unavailable,
and it does not explain the earlier Mylar unsupported-page result.

No denied request was retried using a different host, header, encoding, cookie,
address or route. A legitimate future cloud test requires its network owner to
permit HTTPS CONNECT to `annas-archive.gl:443` and the ordinary metadata routes.
A file host can only be selected after permitted metadata inspection; none is
invented here. NativeHTTPTransport intentionally refuses ambient proxy settings;
an authorized proxy environment must inject a transport that retains that policy,
rather than silently connecting directly. Toshi's successful network context and
exact ordinary exchanges should be verified before comparing live clients there.

Live native search → download remains unverified. The original Mylar failure's
upstream response was not retained, so its exact cause remains unknown. No account,
API key, CAPTCHA bypass, cookie extraction or protected-route workaround was used.
