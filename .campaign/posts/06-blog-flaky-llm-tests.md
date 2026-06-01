# Blog post: "Detecting flaky LLM tests with 3-sample byte-identical hashing"

> **Audience**: people running LLM evals in CI who've felt the "is this real or did the LLM just jitter" pain.
> **Word count**: 900-1100. Shorter than the previous two; the technique fits in less space.
> **Tone**: technical, not preachy.

---

## Title

```
Detecting flaky LLM tests with 3-sample byte-identical hashing
```

## Subtitle

```
A 30-line bash technique that separates real LLM regressions from temperature jitter — without retry-until-pass spirals.
```

---

## Body

LLM tests are flaky in a way that classical unit tests aren't. Same input, same model, same temperature 0 — you can still get subtly different outputs across runs. Whitespace, word ordering in a list, the specific phrase the model uses to refuse.

Most CI systems handle flake by **retrying until pass**. This is wrong for LLM tests because it hides genuine intermittent bugs.

eval-harness does something different. When a case fails, it re-runs 3 times and hashes the outputs byte-for-byte.

- **All 3 identical** → real FAIL, attribute it.
- **Any divergence** → tag `flaky: true`, don't attribute.

That's the whole technique. ~30 lines of bash. This post is why it works, why 3 (not 5 or 2), and how to compose it with attribution.

### The hash needs normalization

You can't hash raw stdout directly. Two genuinely identical LLM responses can differ in:

- Trailing whitespace per line
- ANSI color codes if the runner prints them
- Tool-call arg ordering (Claude sometimes lists `tool_use` args in different orders even at temperature 0)

eval-harness normalizes before hashing. The normalizer ([`scripts/eval/lib/stability.sh`](https://github.com/nano-step/eval-harness/blob/main/scripts/eval/lib/stability.sh)) does:

1. Strip ANSI escape codes (`sed 's/\x1b\[[0-9;]*m//g'`)
2. Collapse runs of whitespace to single spaces
3. Trim line trailing whitespace
4. Sort tool_use args by key when they appear in the transcript JSON
5. Drop trailing empty lines

After normalization, `sha256sum` over the result. Three samples produce three hashes. Compare:

```bash
if [[ "$h1" == "$h2" && "$h2" == "$h3" ]]; then
  verdict="real"
else
  verdict="flaky"
fi
```

### Why 3 samples, not 2 or 5

**2 samples**: false negatives are too easy. If the model produces 80% of outputs identically and 20% jitter, two samples have a 36% chance of matching by coincidence even when the underlying behavior is unstable.

**5 samples**: triples the API cost on every FAIL with marginal precision gain. For an 80/20 model, 3 samples already give ~51% probability of catching the jitter; 5 gives ~67%. Not worth the dollars on a CI gate.

**3 samples** is the sweet spot: 51% catch rate of 80/20 jitter, 3× cost on FAILs only (passing cases never get extra samples), and the hash comparison is dead simple.

If you want to tune: `EVAL_STABILITY_SAMPLES=5` overrides the default. We don't recommend it for cost reasons but the lever exists.

### Composition with 4-class attribution

The stability check sits *upstream* of attribution. The pipeline:

```
case FAILs
  │
  ├──> 3-sample stability check
  │       ├── all identical → real FAIL
  │       │      │
  │       │      └──> 4-class attribution (SKILL_CHANGED / FIXTURE_STALE / MODEL_CHANGED / UNKNOWN_DRIFT)
  │       │
  │       └── divergence    → tag `flaky: true`
  │                  │
  │                  └──> SKIP attribution (don't pretend you can blame a class)
  │
  └──> render diff.md
```

The crucial bit: **flaky cases don't get attributed.** A common bug in eval tooling is to attribute a flake as `UNKNOWN_DRIFT`, which makes the dashboards lie. eval-harness explicitly carves out flakiness so the attribution stats stay honest.

### What `flaky: true` does to your workflow

In `history.ndjson`, every case run records `flaky` as a boolean. You can chart flakiness rate over time:

```bash
eval-harness trend --since=30d --flaky-only
```

If your flakiness rate climbs above ~5% of total runs, something in your suite needs tightening. Common causes I've seen:

- **LLM-judge rubrics that are too vague.** "Is the answer helpful?" → flake. "Does the answer contain at least one URL?" → deterministic.
- **`output_contains` checks on long generation.** The LLM's wording varies; the substring is too narrow. Widen to a regex.
- **MCP server flake** (Anthropic's MCP tool calls occasionally fail upstream; not your bug).
- **Real intermittent bug** in your tool-use logic.

The trend gives you the signal. You decide which.

### What about pass@k?

If you've shipped LLM evals, you've probably heard of [pass@k](https://arxiv.org/abs/2107.03374) — "the test passes if at least k of N samples pass." It's the standard technique in academic benchmarks.

eval-harness will support pass@k as an opt-in mode ([issue #21](https://github.com/nano-step/eval-harness/issues/21)) but it's not the default because:

- pass@k accepts flakiness silently. Your CI passes even when the LLM is unstable. That's wrong for a regression-gate.
- pass@k requires 5-10 samples per case. Cost grows linearly.
- pass@k makes attribution impossible (which sample "really" failed?).

For benchmark numbers, pass@k is right. For CI gating, 3-sample byte-identical is right.

### Try it

The stability check is on by default in v0.4.2. Any FAIL automatically gets re-run 3 times. You'll see `Stability check: 3 samples byte-identical → real FAIL` or `Stability check: samples diverged → flaky` in `diff.md`.

```bash
npm install -g @nano-step/eval-harness
eval-harness run --skill <your-skill>
```

Implementation: [`stability.sh`](https://github.com/nano-step/eval-harness/blob/main/scripts/eval/lib/stability.sh).
Test coverage: [`stability_inline.sh`](https://github.com/nano-step/eval-harness/blob/main/scripts/eval/tests/stability_inline.sh).
Repo: [github.com/nano-step/eval-harness](https://github.com/nano-step/eval-harness).

### Open question

The technique works well in practice but I haven't found a clean theoretical framing for it. The closest is the **3-of-3 quorum** pattern in distributed systems — "if 3 independent observations agree, treat as truth." Different problem space, similar intuition.

If you've seen this technique published elsewhere, I'd genuinely love a citation — both for the eval-harness docs and because I'd rather stand on the shoulders of someone who thought about it harder than I did.

---

*eval-harness is MIT, bash + jq, v0.4.2.*
