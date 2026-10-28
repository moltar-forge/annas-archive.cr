# Offline Python/Crystal parity

Reference: [`meurz/annas-archive-cli`](https://github.com/meurz/annas-archive-cli/tree/001ab3250e9cd829e7225b6385e3fb8aac999090),
commit `001ab3250e9cd829e7225b6385e3fb8aac999090` (`0.2.0rc4`, MIT).
Current local work is based on public shard commit
`ae5274a406365dc5dbd30179c6a7414a57f69bf2`.
The original metadata comparison started at `de06ffac01269ed239ccf5b7ceec9a63f6e9c1c9`.
The Python source was inspected before execution. Four reference module hashes
are enforced by the runner. The four reduced HTML fixtures retain the reference
MIT license in `../fixtures/reference/LICENSE`.

The runner imports the inspected parser/client modules only. `Client.page` is
replaced with its ordinary single-request path, with no challenge retry branch.
`Client.download` is disabled. HTTP uses `httpx.MockTransport` exclusively;
Python DNS/socket entrypoints fail if invoked. Challenge classification uses
pure status/document parsing, never the retrying client method. No CLI entrypoint,
cookies, credentials, browser automation, live requests or real file downloads
are used. These controls are fixture-runner guards, not a claim of OS isolation.

## Reproduce

Provide a checkout of the exact reference commit, then use an isolated Python
3.11+ environment with the pinned test dependencies and Crystal 1.20.2/libxml2:

```sh
python3 -m venv /tmp/anna-parity-env
/tmp/anna-parity-env/bin/pip install -r spec/differential/requirements.txt
python3 spec/differential/compare.py \
  --reference /path/to/pinned/annas-archive-cli \
  --python /tmp/anna-parity-env/bin/python \
  --output /tmp/annas-archive-parity.json
crystal spec
crystal tool format --check src spec
```

The hash guard rejects a different reference source. The checked-in
[`results.json`](results.json) retains each raw result from both implementations;
the comparison script exits nonzero for an unclassified mismatch. Bibliographic
whitespace is folded for comparison, including NBSP; language is case-normalized.
Nullable Crystal fields project to Python’s empty strings. URL bytes, signed query
strings, request parameters and ordering are compared without normalization.

## Results and fixes

Before correction, 6 of the initial 20 cases differed: bibliographic fields and
source labels were omitted, current-record summaries included a Save control,
and explicit page/repeated-filter requests were unavailable. After correction,
**38 cases yield 30 matches, 8 documented differences, zero unexplained mismatches**.
All **45 Crystal specs pass**, including native transport, streaming and output
validation. The additional metadata cases cover Python CLI default request
parameters, its local 20-result limit and deferred cards at document position.

| Behavior | Evidence | Result |
| --- | --- | --- |
| Legacy/current search and deferred cards | Four pinned search/record fixture inputs; titles, author, publisher, language, format, displayed size, covers, record URLs, descriptions, links/labels | Match after metadata fixes |
| Explicit no-results pages | English variants and Chinese | Match; unknown/parked pages fail |
| Comic language/edition/mobile hints | Synthetic titles with issue/year/digital/mobile and English/French summaries | Match in preserved title/summary metadata; neither client performs comic identity matching |
| Query construction | Unicode, ampersand, scalar and repeated language/format, content, page 2/3 and sort | Match; one explicitly requested page, no automatic traversal |
| Ordinary landing controls | Absolute signed URL, relative URL and label-selected link | Match; signed bytes preserved |
| Countdown | Numeric countdown | Match; Crystal returns scheduling data rather than sleeping |
| Ordinary redirect | Same-origin HTTPS redirect through fixture transport | Same requested URLs/final parsed result; native transport enforces exact-host HTTPS redirects and public-address checks |
| Failure classification | Plain 403, 401, 503, 429, recognized challenge, unknown layout, parked domain | Semantic classifications match; Python's generic HTTP code is mapped by status in the oracle |

Intentional measured differences:

- Crystal retains local minimum-interval and server Retry-After cooldowns across
  calls; Python makes another request. The comparison uses a frozen clock and
  makes no actual sleeps or network requests.
- Crystal distinguishes authentication forms, unsupported landing pages and
  malformed countdowns with closed typed errors; Python uses `operation_failed`.
- Crystal rejects a query above 512 bytes and bounds results to 50 per explicit
  page. The reference accepts the larger input and parses 51 fixture records.
- Crystal excludes HTTP source links; the reference emits them as metadata.

Other deliberate boundaries are not parity claims: bounded input/response/link
limits, no cookie import, no challenge-related URL rewriting, no mirror switching
and no CLI process dependency. Mylar separately owns comic identity matching,
import state and application cleanup. See [full download evidence](DOWNLOADS.md)
for the standalone native downloader and the remaining live boundary.
