# Why not promptfoo?

[promptfoo](https://github.com/promptfoo/promptfoo) is the most popular open-source LLM eval tool today (~5k stars, MIT, very active). When I started building eval-harness in May 2026 I evaluated promptfoo first. I still recommend it for most teams.

This page is the honest answer to **"why does eval-harness exist if promptfoo already does this?"** It's organized around four things eval-harness does that promptfoo doesn't, and three things promptfoo does that eval-harness doesn't.

> **One-line summary:** promptfoo is a great _eval framework_. eval-harness is a focused _regression-detection harness_. They solve different problems and compose well.

## What eval-harness does that promptfoo doesn't

### 1. Failure attribution (the killer feature)

When a promptfoo test fails, you get `expected`, `actual`, and a diff. You then spend 20–60 minutes asking yourself:

- _Did my prompt change?_
- _Did the model change under me?_
- _Did the fixture rot?_
- _Is this flaky?_

eval-harness ships a 4-class attribution decision tree that answers that question deterministically using SHA fields captured at baseline + at run time:

```
[FAIL] atom-tags-decision-architecture
Attribution: SKILL_CHANGED (skill_sha 7f3a2c1 → 9d4e1b8, only delta)
```

That's not a magic ML thing. It's a simple ledger: at baseline time we hash the skill, the fixture, and capture `model_id` + `opencode_version`. At fail time we compare. The class that diverged is the class that explains the failure.

promptfoo doesn't have an analogous concept. You _could_ reconstruct it manually from git log + provider metadata. We did it for you.

### 2. The 6-field FAIL schema (not just expected/actual)

promptfoo gives you:

```
✗ output: did not match /yes/i
  received: "I cannot answer that question."
```

eval-harness gives you (per FAIL):

| Field | Value |
|---|---|
| `failed_check_id` | `atom-tags-decision-architecture` |
| `expected` | `$.atoms[].tags[] contains "architecture"` |
| `actual` | `["redux","redaction"]` |
| `diff_hint` | `tag "architecture" missing from atom #2` |
| `transcript_span` | `lines 142-158 of opencode.log` |
| `env_delta` | `skill_sha 7f3a2c1 → 9d4e1b8 (only delta)` |

`transcript_span` and `env_delta` are the two that compound. `transcript_span` lets you jump to the exact place in the log where the LLM produced the wrong thing. `env_delta` overlaps with attribution above but is also a standalone forensic field.

### 3. Honest flaky tagging

When a test fails in promptfoo, you re-run it. If it passes, you assume it was flaky and move on.

That hides bugs.

eval-harness re-runs 3× on FAIL and hashes the outputs byte-for-byte:
- **All 3 identical** → real FAIL, attribute it
- **Any divergence** → tag `flaky: true`, don't attribute

The flaky tag is **first-class**. You see it in `diff.md`. It's recorded in `history.ndjson` so you can chart your suite's flakiness over time. promptfoo treats flakiness as a CI-runner problem; we treat it as a signal.

### 4. $-cost hard ceiling

promptfoo tracks token cost. eval-harness **enforces** it:

```bash
export EVAL_BUDGET_USD=2.00
```

When you blow $2.00 in one day, the harness aborts before the next call. With a clear message. No surprise $400 Anthropic invoice on Monday.

This matters more than it sounds. The single biggest reason teams turn off LLM eval in CI is "it costs too much." Hard cap fixes that.

## What promptfoo does that eval-harness doesn't

### 1. Provider matrix

promptfoo supports 50+ providers. We support whatever your runner supports (today: opencode → Anthropic). If you need to A/B Claude vs GPT-4 vs Gemini, **use promptfoo**.

### 2. Scenario libraries + redteam

promptfoo ships dataset management, scenario libraries, and a full redteam suite. We don't. Different problem.

### 3. Web UI

promptfoo's web viewer is genuinely good for non-engineers. We have CLI + `diff.md` only. (`eval-harness serve` is roadmap v0.9.)

## When to use which

| If your job is to... | Use |
|---|---|
| Test a new prompt against 200 redteam inputs | promptfoo |
| A/B compare two prompts across 5 providers | promptfoo |
| Build a scenario library for QA | promptfoo |
| Gate a `git push` on whether your agent still works | **eval-harness** |
| Gate `npm publish` of a skill on regression check | **eval-harness** |
| Know _why_ a CI failure happened, not just _that_ it did | **eval-harness** |
| Cap your daily LLM-eval bill | **eval-harness** |
| Inspect results in a web UI | promptfoo (or wait for v0.9) |
| Use both, with cross-tool gating | both (see [comparison.md](./comparison.md)) |

## Honest about competitive pressure

This page is going to age. promptfoo is well-maintained and growing fast. They could ship attribution, the 6-field schema, a `flaky` flag, and `--budget` — all four — in a single release. If they do, eval-harness's distinctive value moves to:

- **Bash + jq, no Node runtime.** Smaller dependency footprint.
- **Local-first, no cloud SKU.** Matches the pre-push gating use case.
- **Opinionated, narrower scope.** "We do regression detection. Nothing else." That clarity is a feature.

If promptfoo ships our four features _and_ matches our scope clarity, we'd recommend their tool. We're not trying to win a feature race. We're trying to make regression detection on LLM agents actually work in CI.

## How to try both

Easiest way to evaluate fit:

```bash
# in your project
npm install -g @nano-step/eval-harness promptfoo

# run promptfoo's scenario coverage
promptfoo eval -c promptfoo.yaml --output results.json

# run eval-harness's regression check
eval-harness run --skill <your-skill>

# if you want to gate on the promptfoo result inside eval-harness:
# add a kind: jq_path_contains check that reads results.json
```

Honest comparisons welcome. Open an issue if you find a place where this page is wrong or out of date.
