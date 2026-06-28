# Reddit posts — r/ClaudeAI and r/mlops

Two separate posts. **Do not cross-post identical bodies — Reddit penalizes repost spam.** Tailor each.

---

## Post A — r/ClaudeAI

> **Subreddit**: r/ClaudeAI
> **Best time**: weekday afternoon US-Eastern (16:00-19:00 UTC). This sub is more US consumer-focused.
> **Flair**: `Showcase` if it exists, else `Discussion`.

### Title

```
I tested a Claude agent against itself 100 times in 4 weeks — here's the regression-detection tool I needed
```

### Body

```
TL;DR — built an OSS regression-test harness specifically because Anthropic ships silent claude-3-5-sonnet point releases and I couldn't tell whether my prompts were degrading or the model was.

Real story: in April I pushed an opencode skill that worked perfectly. Two weeks later it started returning weirdly truncated outputs on the same input. I spent half a day blaming my prompt. The actual culprit: claude-3-5-sonnet had silently shipped a minor revision over the weekend. The behavior was different but I couldn't tell because nobody flagged the version bump.

So I built eval-harness around a question every Claude developer needs: **"if a test fails, was it me or was it Anthropic?"**

The way it answers: it captures `model_id` at baseline time, captures it again at run time, and if they differ AND your prompt/fixture are byte-identical to baseline, attribution = `MODEL_CHANGED`. You instantly know it's not your code.

Other bits:

- 6-field FAIL output instead of just expected/actual (adds `transcript_span` so you can jump to the exact line in the agent's transcript)
- 3-sample byte-identical re-run on FAIL to separate real regressions from LLM jitter
- Hard daily $ ceiling so you don't accidentally burn $50 on an eval loop
- Git pre-push hook + GitHub Action shipped

Bash + jq, MIT. v0.4.2.

Repo: https://github.com/nano-step/eval-harness
Why-not-promptfoo comparison: https://github.com/nano-step/eval-harness/blob/main/docs/why-not-promptfoo.md

If you ship Claude agents in prod and you don't have regression detection — this is a free way to catch the silent model changes that bit me. Curious if anyone else has caught Anthropic shipping un-announced model revisions in the wild (I have receipts on 2024 sonnet revisions; happy to share).
```

---

## Post B — r/mlops

> **Subreddit**: r/mlops (smaller, ~80k, more engineer-focused)
> **Best time**: weekday morning US-Eastern (14:00-16:00 UTC)
> **Flair**: `Open Source`

### Title

```
[OSS, MIT] Behavior-regression CI gate for LLM agents — bash + jq, 4-class failure attribution
```

### Body

```
Sharing eval-harness, a regression-detection harness for LLM-agent systems. Designed for the "shadow mode → blocking gate" promotion model that observability tools sell, but local-first / OSS.

**Engineering decisions worth flagging**:

- **Bash + jq + python3 stdlib, no daemon**. The install bar is `npm i -g` + `apt install jq`. Composite GitHub Action shipped. No SaaS.

- **Per-(case,trigger) flock(1) lockfile**. Two concurrent pushes don't corrupt history. mkdir-fallback on macOS where flock isn't standard.

- **`set -euo pipefail` everywhere**. New scripts that don't follow this convention get rejected at review.

- **Honest failure modes**. When `llm_judge` can't get a verdict (API down, response unparseable, majority null) — returns `verdict: null` rather than fabricating. Tests for this explicit (`llm_judge_unit.sh`).

- **3-sample byte-identical stability check** on FAIL, with `flaky: true` tag in `history.ndjson` for trend analysis.

- **4-class attribution** (`SKILL_CHANGED` / `FIXTURE_STALE` / `MODEL_CHANGED` / `UNKNOWN_DRIFT`) via simple SHA-comparison decision tree over an env-manifest captured at baseline.

- **Hard $ daily ceiling** with persistence in `budget.ndjson`. Default $2.00.

- **20 test suites, all green on main**. Includes BSD/GNU grep portability (closed BLK-4 in the audit), fixture path-traversal blocking (BLK-3), sandboxed shell-check filter (BLK-2), timeout-124 → harness-error not vacuous PASS (BLK-8).

- **Warn-only by default** with explicit `promote` command. Auto-promotion (`N green days → blocking`) is v0.6.0.

The MLOps-shaped people I've shared early versions with cared most about: cost ceiling, flake handling, and the env-manifest + attribution combo. If you've shipped LLM eval into CI and turned it off because of cost or noise, this might be the path back.

Repo: https://github.com/nano-step/eval-harness
Comparison vs promptfoo / DeepEval / Ragas / OpenAI Evals (honest table): https://github.com/nano-step/eval-harness/blob/main/docs/comparison.md
LangGraph runner is help-wanted issue #36 if you want a contribution avenue.

What's the regression-detection story on your team today? Curious especially about teams running eval in CI and what % of failures are real vs flake vs model-drift.
```

---

## Response patterns for both subs

If someone questions the bash choice (will happen):
> The harness has to spawn an agent subprocess and capture its transcript regardless of language. Bash is the right glue for that. Wrote a Python version first; it was longer and had more dep-management failure modes. Happy to send the abandoned Python branch if useful.

If someone wants Helm chart / k8s integration:
> Genuinely not the target market today. The Composite Action covers CI; for k8s-resident agents the `bare-anthropic` runner (v0.10.0 roadmap) is the right entry point. Open an issue if it's blocking you.

If someone asks "why not just use OpenAI Evals?":
> OpenAI Evals is great as a reference framework and dataset format. It doesn't ship attribution, flaky tagging, or cost gating, and it's Python-Python-Python. eval-harness fills different gaps. They can coexist.
