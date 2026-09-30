# eval-harness documentation

Current stable release: **v0.5.0**. The CLI is distributed from the GitHub source repository; it is not published to npm.

## Start here

- [Project overview and quick start](../README.md) — supported evaluation types, check kinds, installation, shell trust boundary, and examples.
- [Runner contract](./runners.md) — OpenCode execution and the interface for prepared evidence from other runners.
- [LangGraph example](../examples/langgraph-runner/) — a runnable example of the runner contract.

## Contracts and design

- [v0.5.0 design and migration contract](./EVAL_HARNESS_V2.md) — result states, schemas, compatibility, and deferred scope.
- [Versioning and deprecation policy](../POLICY.md) — including the documented shell-check breaking change.
- [Security policy](../SECURITY.md) — supported versions and the shell execution boundary.
- [Known issues](../KNOWN_ISSUES.md) — verified open limitations.

## Evidence and project history

- [Janus benchmark](./JANUS_BENCHMARK.md) — offline comparison evidence; no native Janus execution adapter is recommended yet.
- [ECC research](./ECC_RESEARCH.md) — design rationale and source evidence.
- [Changelog](../CHANGELOG.md) — changes by release.
- [Contributing](../CONTRIBUTING.md) — tests, review, and release workflow.

All deterministic local tests run with `npm test`. They use fixtures and stub runners; they do not measure live model quality, latency, or cost.
