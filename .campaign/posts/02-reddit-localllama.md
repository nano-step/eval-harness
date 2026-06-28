# Reddit r/LocalLLaMA post

> **Subreddit**: r/LocalLLaMA (1.5M members; tilted toward local-first, OSS, non-cloud)
> **Best time**: weekday morning **US-Eastern** (12:00-14:00 UTC). LocalLLaMA is most active during the US work day.
> **Flair to pick**: `Resources`
> **Don't**: cross-post the same body word-for-word to r/MachineLearning or r/ClaudeAI. Subreddits hate identical copies. Rewrite.

---

## Title (300 char limit but keep < 100)

```
I built a behavior-regression test runner for LLM agents — bash + jq, MIT, with attribution
```

## Body

```
Hey r/LocalLLaMA — quick share of a tool I've been building, hoping for honest feedback.

Problem I had: I ship a bunch of opencode skills (custom prompts/agents that opencode loads). Every push I'd worry "did I break the one that summarizes meeting notes?" Existing eval tools (promptfoo, DeepEval) tell you a test failed but not _why_. So when the regression happens at 4pm Friday, you spend an hour figuring out whether it was your prompt edit or the model.

**eval-harness** is built around that "_why_" question. Four things make it different:

1. **4-class attribution** — when a case fails, the harness compares SHA fields captured at baseline + at run time, and emits one of: `SKILL_CHANGED`, `FIXTURE_STALE`, `MODEL_CHANGED`, `UNKNOWN_DRIFT`. Deterministic decision tree, no magic ML.

2. **6-field FAIL schema** — not just `expected/actual` but also `transcript_span`, `env_delta`, `diff_hint`, `failed_check_id`. Saves the "where did this come from" 20-minute debugging session.

3. **3-sample stability check** on FAIL — re-runs the failing case 3× and hashes the outputs byte-for-byte. All identical → real FAIL, attribute. Any divergence → tag `flaky: true`, don't attribute. Treats flakiness as a first-class signal, not a "just retry until green" CI smell.

4. **$-cost hard ceiling** — `EVAL_BUDGET_USD=2.00` aborts the run before you wake up to a $400 Anthropic invoice. The single biggest reason teams turn off LLM eval in CI.

It's bash + jq + python3 stdlib. No daemon, no Node CLI. MIT. Ships a git pre-push hook and a composite GitHub Action. v0.4.2 closed 8 BLOCKERs from independent audits — being honest, the project is 4 weeks old.

Repo: https://github.com/nano-step/eval-harness
Concepts (4 core ideas, 10-min read): https://github.com/nano-step/eval-harness/blob/main/docs/concepts.md
Honest comparison vs promptfoo / DeepEval / Ragas / OpenAI Evals: https://github.com/nano-step/eval-harness/blob/main/docs/comparison.md

Today it works with opencode skills. LangGraph and Claude-Agent-SDK runners are open issues (help wanted, ~150 lines of bash per runner). If you ship LLM agents and want regression testing, the LangGraph runner PR is the highest-leverage contribution right now.

**What I'd love feedback on**:
- Is 4-class attribution the right granularity? I deliberately collapsed `MCP_FLAKE` and `HARNESS_BUG` into `UNKNOWN_DRIFT` because I couldn't reliably distinguish them.
- Is 3-sample stability enough, or should I default to 5?
- What's a regression on YOUR LLM agent that current tools miss?

Happy to answer anything. No SaaS, no upsell — just curious if this resonates.
```

---

## Response style

LocalLLaMA likes: technical honesty, OSS-first thinking, distrust of cloud/upsells, real numbers.
LocalLLaMA dislikes: marketing voice, "revolutionary", emojis (use sparingly or not at all — this draft has none on purpose), implication that anyone who disagrees doesn't get it.

If someone says "this is just X with extra steps", reply:
> Possibly fair. The novel part isn't any one piece, it's the combination + attribution layer. If X already does attribution, please link — I'll borrow what I can and credit.

If someone asks "does this work with [local llama.cpp setup]":
> Not yet, because the only shipped runner is opencode (which routes to Anthropic by default). The runner contract is small enough that a `llama-cpp` runner is ~150 lines. Open an issue if you want to build it, I'll mentor.

If someone asks "how is this different from your own opencode-internal testing":
> Honest answer: it _started_ as opencode-internal testing. I extracted it into a separate tool because the attribution layer + stability check + cost ceiling generalize to any LLM-agent regression problem, not just opencode skills.
