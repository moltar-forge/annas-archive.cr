# Record link cap hotfix evidence

- Branch: `fix/record-link-cap`
- Commit: `d7daf25` — fix: allow bounded records with up to 128 download links
- Trailer: `Co-authored-by: Holden Omans <holden.omans@gmail.com>`

## Scope

Changed only `src/annas_archive/client.cr`, `spec/record_link_limit_spec.cr`, `README.md`, and `docs/api.md` in the commit. Added `MAX_RECORD_LINKS = 128` and replaced the old literal 20-link bound. 128 provides headroom above the observed 38 while retaining a small finite result allocation and the existing 1 MiB page bound. No truncation; link 129 raises `result_limit`. URL resolution, filtering, deduplication, order, labels and transport policy are unchanged.

Regression coverage: 21 links; observed distribution of 38 (21 member, 16 browser/slow, one external); exact signed-query encoding/order/repeated and empty parameters; 128 unique links; duplicates and rejected URLs before/after the bound; 129th unique valid link overflow; oversized detail page rejection. Synthetic HTML only.

## Commands and results

- `crystal tool format src/annas_archive/client.cr spec/record_link_limit_spec.cr` — exit 0; aligned constants in client.
- `crystal spec` — exit 0; 64 examples, 0 failures, 0 errors, 0 pending (321.39 ms execution).
- `crystal tool format --check src spec examples` — exit 0.
- `git diff --check` — exit 0.
- `git diff --cached --check` — exit 0 before commit.
- `git log --oneline origin/main..HEAD` — only scoped commit `d7daf25`.
- `git show --stat --oneline HEAD` — four expected implementation/test/documentation files.

## Risks and handoff

Records above 128 unique valid URLs still fail explicitly; larger legitimate records would require revisiting the documented bound. Live behavior remains for parent independent validation; no live requests, push, PR, merge, tag or deployment performed. Manifest lifecycle was not edited; its existing working-tree modification and untracked hotfix note were preserved. This evidence is a lane-local handoff artifact, outside the implementation commit.

## Parent independent verification — 2026-10-28

Implementation reviewed at d7daf25 from main cca3449. Parent ran crystal spec: 64 examples, zero failures/errors/pending; format and git diff --check passed. Standalone synthetic EPUB workflow passed MD5/SHA-256 and ZIP CRC validation. Offline metadata: 30 matches/8 intentional differences; downloads: 7 matches/1 intentional difference; challenges: 8 matches. Zero unexplained mismatches.

Live native test on Moltar at 18:57–18:58 UTC used annas-archive.gl and the same Pride and Prejudice record that failed previously. Public-domain title identity checked; no Toshi, Python/CLI runtime, proxy, mirror switching, safety-policy relaxation or deployment. Test harness: /tmp/anna-record-link-live.cr; sanitized transcript: /tmp/anna-record-link-live-results.jsonl.

- Record challenge cleared with one metadata compatibility retry; all 38 links returned (21 member, 16 browser, 1 external).
- Waited 31 seconds before resolving the first same-origin slow link.
- Slow route 403 challenge cleared with one encoded-prefix retry, returning 200 and an explicit file control.
- File host wbsg8v.xyz returned 200; no mirror cookies sent to it.
- 7 total HTTP exchanges; no countdown presented for this link.
- Download: 278472 bytes, MD5 dba7a9943ea918a5afd2b170527fca13, SHA-256 405bf13598588dbca100cac3cb137ede869e7a0f27e6dccab14a658d7c936fc5.
- Native Downloader returned validation zip_crc after EPUB structure/CRC checks and atomic publication.
- Removed the stale README claim that full live downloads are unverified.

Scope remains record-limit repair, regression tests, current documentation and lane evidence. No unsupported features, release edits, merge, deployment or Mylar changes. v0.3.0 is unchanged. Parent next action: publish and verify scoped PR; report remaining 128-link bound.

## Publication

PR #3: https://github.com/moltar-forge/annas-archive.cr/pull/3 (open; no CI workflows/checks configured; no review requested). Parent verified initial four-file implementation scope and then added current README and lane evidence. Independent system md5/shasum match the Downloader results above; unzip -t reports no compressed-data errors. Parent final acceptance: clean worktree, final published head equality and seven-file scoped PR inspection. No merge or release promotion performed.

## Concurrent upstream reconciliation

While PR #3 was publishing, Holden commit 2a60c08 landed the same 128-link repair on main, with additional 256-source-anchor, 4096-byte URL and 1024-byte label bounds. Merged main into this branch without replacing the upstream implementation; src/annas_archive/client.cr is byte-identical to main. Updated the duplicate regression to remain within the new source-anchor bound, preserving its unique-link overflow check. All 66 specs and formatting passed on the reconciled tree. The PR now supplies extra regression coverage, corrected docs and live verification rather than a second production implementation. Final live verification and publication follow below.
