# Native challenge compatibility evidence (0.3.0)

Task base: `bd0de799b9a617aca572c5768c0baf6fe70f4020`.
Reference: MIT-licensed `meurz/annas-archive-cli` at
`001ab3250e9cd829e7225b6385e3fb8aac999090`.
The pinned `src/anna/client.py` and `tests/test_anna.py` were inspected via
GitHub API. Source attribution remains in NOTICE and the retained MIT license.

## Reproduce locally, offline

Use the pinned dependencies and reference modules described in README.md:

```sh
crystal spec
crystal tool format --check src spec
python3 spec/differential/compare_challenges.py \
  --reference /tmp/anna-challenge-reference \
  --python /tmp/anna-challenge-env/bin/python \
  --output spec/differential/challenge-results.json
python3 spec/differential/compare.py \
  --reference /tmp/anna-challenge-reference \
  --python /tmp/anna-challenge-env/bin/python \
  --output spec/differential/results.json
python3 spec/differential/compare_downloads.py \
  --reference /tmp/anna-challenge-reference \
  --python /tmp/anna-challenge-env/bin/python \
  --output spec/differential/download-results.json
```

Unlike the older ordinary-workflow oracle, the new challenge oracle executes the
original pinned Python `Client.page` and `Client.download` methods. It verifies
all four imported module hashes, uses only httpx.MockTransport and disables Python
socket/DNS entrypoints. No Python CLI entrypoint runs. The Crystal runner uses
NativeHTTPTransport's real header construction, response-cookie retention and
URL/redirect policy, fake public DNS, and an exchange seam replacing socket/TLS
I/O. These are fixture guards, not OS sandboxing or real TLS evidence.

## Results

`challenge-results.json`: **8 matches, 0 mismatches**, comparing exact URL bytes,
cookie headers, terminal outcome, file count, byte count, MD5 and SHA-256:

- Search challenge → successful raw `check=%31` retry with Unicode query and
  repeated EPUB/PDF filters, preserving session cookie.
- Persistent search challenge → exactly two requests.
- Plain 403 → one request; second-request 429 → rate-limited, no third request.
- Same-configured-mirror slow route → one `/slow%5Fdownload/` retry, retaining
  all repeated/empty/signed raw query bytes and session cookie; validated EPUB.
- Persistent slow challenge → two requests and no file.
- External-host or already-encoded slow route → one request, no rewrite/file.

The success fixture remains 599 bytes, MD5
`ac20330c40fdf2dfce2d0ea3eddb5632`, SHA-256
`bb10deee9fb40087ece40165dd4b15fc40c7f4284709f1fcb7fb852f0408516f`.
The original metadata suite remains 30 matches / 8 intentional differences;
ordinary downloads remain 7 matches / 1 intentional CRC-publication difference.
No unexplained mismatch exists in these reports. The metadata report compares
only the final challenge error, not retry request parity; the new report supplies
that missing evidence.

The full standalone native flow in `spec/challenge_retry_spec.cr` performs
search → detail → Client.resolve → Downloader after four recognized challenges
(eight exchanges total), sharing the native cookie session. It checks every
rewritten URL, full signed query bytes, MD5/SHA-256, ZIP CRC/EPUB validation and
atomic publication. Additional specs cover opt-out/unconfigured origins, plain
401/403/429/error/network failures, second-request typed and HTTP cooldowns,
charged minimum intervals, body bounds, cancellation, redirect confinement,
actual native request cookie headers and session host/path/Secure/expiry rules.
Existing DNS/TLS/deadline/proxy/file-safety regression specs still run.

## Deliberate limits

Default retries are enabled, but never general retries or solvers. Client landing
resolution is limited to its configured origin. Downloader needs an explicit
`origin:` before it can rewrite a slow route; arbitrary external paths never
receive rewrite authority. Countdown scheduling remains caller-owned. Metadata
requests retain their per-call transport deadlines; download retry shares one
original total deadline/cancellation context. The memory-only cookie jar narrows
Domain attributes to exact hosts, bounds storage to 32 × 1024 bytes, and caps
positive Max-Age retention at one year. Browser import and connection pooling
are not implemented.

All testing for this port ran locally on Moltar, Crystal 1.20.2/macOS arm64.
There were no live Anna challenge probes, Toshi tests, deployment, mirror changes
or proxy bypasses. Historical offline and cloud/Toshi evidence elsewhere in this
repository is not proof that the new native retries work live. Native live
search → verified file acquisition remains unverified; any future authorized
live verification belongs to the parent task.
