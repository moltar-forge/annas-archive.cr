# Challenge retry port lane evidence

- Task: native adaptation of pinned Python recognized-challenge workaround.
- Checkout: /Users/moltar/.openclaw/workspace/repos/_lanes/annas-archive/challenge-retry
- Branch: feat/python-challenge-retries
- Base: bd0de799b9a617aca572c5768c0baf6fe70f4020
- Reference: meurz/annas-archive-cli @ 001ab3250e9cd829e7225b6385e3fb8aac999090 (MIT).
- Status: implementation ready for parent verification; parent owns final completion/publication.
- No other worker edited this checkout. No push, PR, merge, deployment, live Anna probe or Toshi test performed.

## Scope and decisions

Inspected pinned Python src/anna/client.py and tests/test_anna.py directly via gh
API, as well as parser challenge classification and four hash-pinned modules.
Read repository/source/docs and GitHub skill. No repository AGENTS.md exists.
Kept existing constructors compatible; appended named optional retry policy and
Downloader origin. Version/description now 0.3.0; MIT attribution remains.

Default Client retries once only for recognized challenge errors. Search/detail
append literal check=%31; resolve rewrites the original configured-origin slow
prefix only. Downloader requires explicit origin before rewriting any slow route,
and retries before file bytes only, sharing one deadline/cancellation context.
All signed/repeated query bytes remain unchanged. Opt-out is challenge_retries:
false. Exhausted or out-of-scope challenges retain browser_verification_required.
No generic retry, solver, proxy bypass, mirror change or new redirect authority.

Shared NativeHTTPTransport retains memory-only response cookies, including from
challenge/redirect responses. Exact-host only (even Domain cookies), RFC default
path/boundaries, Secure, Expires, Max-Age precedence/deletion, quoting, replacement
and secure prefixes. Storage: 32 × at most 1024-byte cookie inputs; invalid/excess
cookies ignored, positive Max-Age capped at one year. No browser-cookie import.
Actual native request-header construction is exercised below the perform seam;
only exchange sockets/TLS are replaced by offline fixtures.

Rate-limit cooldowns survive either response and typed transport errors. Metadata
keeps per-request page/deadline policy (30 seconds default per native page call),
while download retry shares its original total transfer deadline. Existing
DNS/TLS/redirect/proxy/size/cancellation and atomic validated-publication gates
remain intact and run in regression specs.

## Exact local verification commands

Run from the checkout above (Crystal 1.20.2, macOS arm64):

    crystal spec
    crystal tool format --check src spec
    python3 spec/differential/compare.py --reference /tmp/anna-challenge-reference --python /tmp/anna-challenge-env/bin/python --output spec/differential/results.json
    python3 spec/differential/compare_downloads.py --reference /tmp/anna-challenge-reference --python /tmp/anna-challenge-env/bin/python --output spec/differential/download-results.json
    python3 spec/differential/compare_challenges.py --reference /tmp/anna-challenge-reference --python /tmp/anna-challenge-env/bin/python --output spec/differential/challenge-results.json
    git diff --check
    git log --oneline origin/main..HEAD

Reference files were fetched via gh API at the pinned revision into
/tmp/anna-challenge-reference/src/anna. A local isolated venv was created with
python3 -m venv /tmp/anna-challenge-env, then its pip installed the exact pinned
spec/differential/requirements.txt. These are test-only Python dependencies;
the shard executes no Python/CLI/browser runtime. Oracle guards hash-check
all four imported modules and forbid real socket/DNS calls.

Results:
- Crystal: 59 examples, 0 failures, 0 errors, 0 pending.
- Format: passed; diff whitespace gate: passed.
- Metadata differential: 38 cases, 30 matches, 8 documented intentional differences, 0 mismatches.
- Ordinary download differential: 8 cases, 7 matches, 1 documented CRC-publication difference, 0 mismatches.
- New challenge differential: 8 matches, 0 mismatches, including exact URLs/cookies, bounded failures and verified EPUB artifact hashes.
- Original metadata outcome-only challenge case does not compare retry exchanges; new challenge-results.json does, with original pinned Python retry methods enabled offline.
- Standalone native search → detail → resolve → Downloader success test uses eight exchanges (four challenge/success pairs), same transport cookie session, exact signed queries, MD5/SHA-256, ZIP CRC/EPUB checks and atomic publication.
- Full details and reproduce commands: spec/differential/CHALLENGES.md.

## Recovery and remaining risks

Parent should review the final scoped commit, rerun the gates at exact HEAD, and
own any publishing. No production state changed. Revert the single lane commit
for repository recovery; there is no deployed rollback. Temporary reference and
venv are disposable /tmp test artifacts. Atomic publication behavior is unchanged;
normal failures remove private partials, process termination may leave one.

All evidence is local/synthetic; live native search → verified file acquisition
remains unverified. Historical offline/cloud/Toshi observations are not proof of
live retry acceptance. No claim is made that this compatibility encoding works
against a current challenge. No product decision blocker was needed.
