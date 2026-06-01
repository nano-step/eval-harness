# Concepts

A 10-minute read covering the four ideas that distinguish eval-harness from other LLM eval tools:

1. **The 6-field FAIL schema** — why most eval failures are useless
2. **4-class attribution** — telling you _why_ something regressed
3. **3-sample stability check** — separating real failures from LLM jitter
4. **$-cost gating** — keeping your eval bill from eating your AWS bill

You can read this without knowing anything about opencode. The concepts generalize to any LLM-agent system.

---

## 1. The 6-field FAIL schema

Most LLM eval tools, when a test fails, print something like:

```
✗ Expected output to match: /yes/i
  Received: "I cannot answer that question."
```

That tells you _that_ it failed. It tells you almost nothing about _why_, _where_, or _what to do next_.

eval-harness writes every FAIL as a 6-field record:

| Field | Why it's there | Example |
|---|---|---|
| `failed_check_id` | Stable identifier so you can grep history | `atom-tags-decision-architecture` |
| `expected` | What the case actually asserted (verbatim from YAML) | `$.atoms[].tags[] contains "architecture"` |
| `actual` | What the LLM actually produced, structurally | `["redux","redaction"]` |
| `diff_hint` | One-sentence narrowing of the gap | `tag "architecture" missing from atom #2` |
| `transcript_span` | Line range in the opencode/agent transcript where the relevant output was emitted | `lines 142-158 of opencode.log` |
| `env_delta` | What changed in the environment since the baseline | `skill_sha 7f3a2c1 → 9d4e1b8 (only delta)` |

The `env_delta` field is the one most tools skip. **Without it, you cannot tell whether the test failed because the skill changed, because the fixture is stale, or because the model under the hood quietly shipped a new version.**

(Anthropic shipped four `claude-3-5-sonnet` minor revisions in 2024 alone, none of them announced by version bump. Your eval suite started failing one Tuesday morning. You blamed your prompt. You were wrong.)

## 2. 4-class attribution

Once you have `env_delta`, you can attribute failures into a small fixed set of classes. We picked four:

| Class | What happened | What you should do |
|---|---|---|
| `SKILL_CHANGED` | The skill file changed since the baseline. Likely your edit broke something. | Read the diff. Either fix the skill or update the baseline. |
| `FIXTURE_STALE` | The fixture directory changed but the skill didn't. Probably a stale test artifact. | `eval-harness accept --case <id>` to bless the new fixture. |
| `MODEL_CHANGED` | The skill and fixture are byte-identical to baseline. The model ID or version drifted. | Model upgrade caused the regression. Pin the old model, or update baseline + decide whether the new behavior is acceptable. |
| `UNKNOWN_DRIFT` | None of the above changed. Something nondeterministic happened. | 3-sample stability check kicks in. If unstable → `flaky: true`. If stable → file an issue. |

This is **not** a probabilistic classifier. It's a deterministic decision tree over a small set of SHA fields captured at baseline + at run time. The whole tree fits in one page (see [`scripts/eval/lib/attribute.sh`](../scripts/eval/lib/attribute.sh)).

Why four classes and not three or five?

- **Three** loses `MODEL_CHANGED`, which is the most common silent regression cause in 2025-2026.
- **Five** would split `UNKNOWN_DRIFT` into `MCP_FLAKE` and `HARNESS_BUG`. Both are designed in the type system but **not shipped** because we couldn't reliably distinguish them in practice. Honesty over false precision.

(See [the v0.4.2 changelog](../CHANGELOG.md) — `attribute.sh` portability across GNU and BSD grep was BLK-4 in the audit.)

## 3. The 3-sample stability check

LLMs are stochastic. Even at temperature=0, the same prompt can produce subtly different outputs on different runs — different whitespace, different word order in a list, different cluster of training data sampled.

**Naïve eval framework**: run the test once. Report PASS/FAIL.
- Problem: a single jittery run looks like a real regression and burns half a day of debugging.

**Standard mitigation**: re-run failing tests N times, take majority vote.
- Problem: hides genuine intermittent bugs.

eval-harness's approach: when a case FAILs the first time, **re-run it 3 times and hash the outputs byte-for-byte**.

```
3 samples, all byte-identical → real FAIL (proceed to attribution)
3 samples, ≥ 1 differs        → tag `flaky: true`, don't attribute
```

This is cheap (the model only runs 3 extra times on the failing cases, not on every case), it's deterministic, and it surfaces flakiness as a first-class signal rather than hiding it.

The hash is over the **normalized transcript** (whitespace-collapsed, ANSI stripped, tool-call args canonicalized). Implementation: [`scripts/eval/lib/stability.sh`](../scripts/eval/lib/stability.sh).

## 4. $-cost gating

LLM evals are expensive. A 50-case suite × 3 stability samples × $0.003/call = $0.45/run. Run it on every push from 10 engineers, 5 pushes/day = $22.50/day = $682.50/month just for eval. (Real numbers from a beta tester. Names omitted.)

eval-harness ships a hard daily cost ceiling:

```bash
export EVAL_BUDGET_USD=2.00   # cap at $2/day, default
```

Every case run accumulates against the budget. When the day's budget is exhausted, subsequent runs abort fast with a clear message. The budget file (`$EVAL_STATE_DIR/budget.ndjson`) resets at midnight UTC.

Each run also produces a `summary.total_cost_usd` so you can chart cost-per-case over time and catch _cost regressions_ — a check rewrite that doubled tokens, a prompt edit that 5×'d output length.

(Per-token rates come from [`pricing.json`](../pricing.json), which is curated for haiku-3-5, sonnet-4-6, opus-4-7. We tag the file with a staleness gate — if your pricing.json is > 60 days old, the harness warns. Anthropic's pricing has changed twice in the last 18 months. Yours will too.)

---

## Why a 5th idea isn't here

People ask: "Why no semantic similarity scoring? Why no embedding diff?"

Honest answer: because we couldn't make either one **diagnose** a failure. They can tell you "your output is 78% similar to baseline." They cannot tell you the missing concept is the `"architecture"` tag in atom #2.

eval-harness is opinionated about **deterministic checks first, LLM-judge second, never embedding-only.** The LLM-judge check kind exists (with 3-sample majority voting + explicit `verdict: null` on parse failure), and is the right tool for prose-output skills. But it sits in a row of 6 check kinds, not at the center.

If you need vector-similarity eval, [promptfoo](https://github.com/promptfoo/promptfoo) has a good implementation. The two tools compose well — see [`comparison.md`](./comparison.md).

---

## Further reading

- [`comparison.md`](./comparison.md) — eval-harness vs promptfoo / DeepEval / Ragas / OpenAI Evals
- [`runners.md`](./runners.md) — the runner abstraction + path to non-opencode runners
- [`why-not-promptfoo.md`](./why-not-promptfoo.md) — direct head-to-head: where each tool wins
- [`../standards/skill-quality-v1.md`](../standards/skill-quality-v1.md) — separate, deferred concern: skill _design_ review
