# Offline Python/Crystal parity

Reference: [`meurz/annas-archive-cli`](https://github.com/meurz/annas-archive-cli/tree/001ab3250e9cd829e7225b6385e3fb8aac999090),
commit `001ab3250e9cd829e7225b6385e3fb8aac999090` (`0.2.0rc4`, MIT).
Shard baseline: `de06ffac01269ed239ccf5b7ceec9a63f6e9c1c9`.
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
**35 cases yield 27 matches, 8 documented differences, zero unexplained mismatches**.
All **26 Crystal specs pass**. Mylar adapter/native lifecycle compatibility
validation passed **27 backend examples**, including synthetic capture, MD5
verification, validation/import and portable backup after cleanup.

| Behavior | Evidence | Result |
| --- | --- | --- |
| Legacy/current search and deferred cards | Four pinned search/record fixture inputs; titles, author, publisher, language, format, displayed size, covers, record URLs, descriptions, links/labels | Match after metadata fixes |
| Explicit no-results pages | English variants and Chinese | Match; unknown/parked pages fail |
| Comic language/edition/mobile hints | Synthetic titles with issue/year/digital/mobile and English/French summaries | Match in preserved title/summary metadata; neither client performs comic identity matching |
| Query construction | Unicode, ampersand, scalar and repeated language/format, content, page 2/3 and sort | Match; one explicitly requested page, no automatic traversal |
| Ordinary landing controls | Absolute signed URL, relative URL and label-selected link | Match; signed bytes preserved |
| Countdown | Numeric countdown | Match; Crystal returns scheduling data rather than sleeping |
| Ordinary redirect | Same-origin HTTPS redirect through fixture transport | Same requested URLs/final parsed result; production redirect security belongs to injected transport |
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

Other deliberate boundaries are not parity claims: HTTPS origin validation,
private-network/DNS/redirect policy delegated to the embedding transport,
response/link limits, no cookie import, no challenge-related URL rewriting,
no mirror switching, no CLI process dependency, and no standalone file downloader.
Mylar owns native capture/MD5 verification, comic matching, archive validation,
import and cleanup. A standalone metadata shard is not equivalent to the CLI's
complete file-downloader command.

The original live Anna search denial remains unresolved. Fixture parity does not
show that anonymous search works from the Mylar server. No denied route was retried
and no challenge workaround was executed or ported.
