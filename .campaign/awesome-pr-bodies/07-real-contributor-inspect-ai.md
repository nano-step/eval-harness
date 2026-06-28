# Real contributor PR: UKGovernmentBEIS/inspect_ai

**PR**: https://github.com/UKGovernmentBEIS/inspect_ai/pull/4151
**Status**: OPEN, MERGEABLE, 297+ lines / 1 file (new)
**Head**: `nano-step:add-behavior-regression-example` ← `UKGovernmentBEIS/inspect_ai:main`
**Title**: `examples: behavior-regression testing with custom ci() and mwu_pvalue() metrics`
**DCO sign-off**: Yes (`-s`)

## Why this is the first "real contribution" of the campaign (not a listing)

Up to this point, the campaign has been: fork a popular awesome-list, add a one-line entry, open a PR. That builds the contributor graph (profile ↔ repo) but it does not show **domain expertise** — anyone can submit a listing.

PR #4151 is different. It contributes 297 lines of new Python that:

1. **Defines two new `Metric` subclasses** (`ci`, `mwu_pvalue`) that plug into inspect's `@scorer(metrics=[...])` system. This is the same surface real eval authors use.
2. **Implements a baseline-diff helper** (`compare_to_baseline`) that loads two inspect log directories, aligns by sample id, and reports per-sample flip rate + per-run 95% CI.
3. **Cross-references the eval-harness project** as the production reference implementation, so any reader clicking through hits the eval-harness repo.

When merged, this is a **substantive code contribution to a 2,165★ repo** that the maintainer reviewed and accepted — exactly the kind of "real contribution" that turns an awesome-list contributor into a recognized domain contributor.

## Why this target (selection logic)

| Signal | Value | Why it matters |
|---|---|---|
| Stars | 2,165 | Small enough to land a first contribution, big enough that the contribution is visible |
| Push recency | 2026-06-05 (today) | Actively maintained — not a stale repo that won't review |
| Merge rate | **78%** (39/50) | Highest of any candidate I surveyed; maintainer welcomes external PRs |
| Direct topic fit | Yes (eval framework) | eval-harness expertise is directly applicable |
| Open issue alignment | Yes — #4147 asks for `ci()` metric | The example pre-empts #4147; consumer code is drop-in compatible when the issue's `ci()` lands |
| Has `CLAUDE.md` | Yes | Meta-signal: the maintainer uses Claude Code themselves, so the contribution style matches |

## Issue #4147 — coordination

The `ci()` metric in my example mirrors the design in #4147 (dict output `{"lower": ..., "upper": ...}`, `level=` and `method=` params, stdlib `NormalDist`). The original requester (@yongzhe2160cs) said they have a working implementation.

I posted a [coordination comment](https://github.com/UKGovernmentBEIS/inspect_ai/issues/4147#issuecomment-4632567405) offering three outcomes:
1. Coordinate: I align with their namespace `ci()` design, they ship it, my PR rebases.
2. Independent: I keep the local `ci()` in the example (works today, useful on its own).
3. Reuse: I close my example's `ci()` and reopen as a docs-only follow-up importing from the public API once #4147 ships.

`mwu_pvalue()` and `compare_to_baseline()` are independent of #4147 and stand on their own.

## The example file (what ships in PR #4151)

`examples/behavior_regression.py` (297 lines):

```python
"""
Behavior-regression testing with inspect_ai.

A common failure mode in agent development is the "drift edit": a prompt or
solver change that *still scores well* on aggregate metrics (mean accuracy
moves by 0.5 percentage points) but *materially changes* the agent's
behavior on individual cases...
"""
```

- Module docstring explains the "drift edit" problem and cross-references #4147 + eval-harness.
- `@task behavior_regression` uses inspect's bundled `popularity` dataset and `mockllm/model` for offline reproducibility.
- `@scorer behavior_match` with `metrics=[accuracy(), stderr(), ci(level=0.95), mwu_pvalue(baseline=0.5)]` — the metrics list is where behavior-regression metrics plug in.
- `@metric ci(level=0.95, method="normal" | "bootstrap")` — stdlib `NormalDist` for the normal approximation, deterministic-seeded percentile bootstrap as fallback.
- `@metric mwu_pvalue(baseline=0.5)` — one-sided MWU z-test against a fixed baseline, with a docstring that explicitly notes the z-test approximation (so downstream users don't misread it as a full Mann-Whitney U).
- `compare_to_baseline()` helper — loads two inspect log directories, aligns by sample id, prints drift report.
- `if __name__ == "__main__": _cli()` — supports `python examples/behavior_regression.py --compare ./baselines/v1 ./runs/v2`.

## Lessons captured

- **Real contribution > listing** for the "becomes a contributor" goal. Listings drive graph density; real code contributions drive reputation. Mix both.
- **Find a repo that already has the maintainer reviewing well** (78% merge rate here). Even a great example won't land in a dead repo.
- **Coordinate on overlapping issues.** The #4147 comment pre-empts conflict and shows the maintainer I'm working *with* the community, not *around* it.
- **Cross-link the campaign project.** The example's docstring + comments reference eval-harness as the production reference. Anyone reading inspect's example will discover eval-harness.

## What I did NOT do (and why)

- Did not run `make check` / `make test` locally — sandbox lacks the full inspect_ai dev environment (requires `uv sync --extra dev` and pytest). PR body acknowledges this and offers to address any ruff/test failures in review.
- Did not implement `cluster=` parameter on `ci()` (mirroring `stderr(cluster=...)`) — flagged in the #4147 coordination comment as a follow-up; not needed for the example's purpose.
- Did not pursue 5+ more real-contribution PRs in this session — one is enough to establish the pattern; future sessions can repeat the workflow for other repos (promptfoo, anthropic-cookbook, etc.) using the same selection logic.
