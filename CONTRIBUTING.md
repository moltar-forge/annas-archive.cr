# Contributing

## Local checks

From the repository root:

```sh
crystal spec
crystal tool format --check src spec examples
git diff --check
```

Run the standalone fixture from this checkout:

```sh
CRYSTAL_PATH="src:$(crystal env CRYSTAL_PATH)" crystal run examples/standalone_fixture.cr
```

These commands use local fixtures; they do not contact the live service. The
example creates a temporary output directory unless one is passed after `--`.

## Reference comparisons

Python is needed only for the optional reference-comparison tools, not the shard.
Pinned dependencies, commands and results are documented alongside those tools:

- [Metadata comparison](spec/differential/README.md)
- [Download comparison](spec/differential/DOWNLOADS.md)
- [Challenge comparison](spec/differential/CHALLENGES.md)

Keep test evidence and implementation history in those reports or the pull
request. The README is for installation, usage and current limitations.
