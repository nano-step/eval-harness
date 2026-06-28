# HN Show post — eval-harness launch

> **Submit at**: https://news.ycombinator.com/submit
> **Best time**: Tuesday or Wednesday, **8:00 AM PST** (3:00 PM UTC). Avoid Mondays (drowned by weekend backlog) and Fridays (low traffic before weekend).
> **Title field**: copy/paste line below verbatim
> **URL field**: https://github.com/nano-step/eval-harness
> **Text field**: paste the body below

---

## Title (80 chars max — HN trims hard)

```
Show HN: Eval-harness – behavior-regression testing for LLM agents
```

(81 chars. If HN complains, drop "Show HN: " — they auto-prefix.)

## Body (no formatting on HN — plain paragraphs, blank line between)

```
Hi HN — I've spent the last 4 weeks building a tool for the problem nobody on my team wanted to own: "did this LLM agent regress since last week, and if it did, why?"

Existing tools (promptfoo, DeepEval, Ragas, OpenAI Evals) all tell you THAT a check failed. They give you `expected` and `actual`. They don't tell you whether the regression came from your prompt edit, a stale fixture, the model silently upgrading under you, or just LLM jitter.

eval-harness is built around 4 ideas:

1. A 6-field FAIL schema (instead of expected/actual): adds `transcript_span`, `env_delta`, `diff_hint`, `failed_check_id`. The `env_delta` field captures what changed in the environment since baseline — that's the single biggest debugging time-save.

2. 4-class attribution. A simple decision tree over SHA fields says SKILL_CHANGED, FIXTURE_STALE, MODEL_CHANGED, or UNKNOWN_DRIFT. Anthropic shipped 4 minor revisions of claude-3-5-sonnet in 2024 without announcing them. You blamed your prompt. You were wrong.

3. 3-sample byte-identical stability check on FAIL. If samples diverge, tag the case `flaky: true` and DON'T attribute. First-class flake handling instead of CI retry-until-pass.

4. $-cost hard ceiling (EVAL_BUDGET_USD=2.00 default). The single biggest reason teams turn off LLM eval in CI is "it costs too much." Hard cap fixes that.

It's bash + jq + python3 stdlib. No daemon, no Node CLI, no SaaS, MIT. Ships with a git pre-push hook and a GitHub Action.

v0.4.2 closed 8 BLOCKERs surfaced by independent audits — I'm being honest that the project is 4 weeks old, but the internals are solid (20/20 test suites green, including BSD-grep portability, fixture path-traversal blocking, and a sandboxed shell-check filter).

Works with opencode skills today. LangGraph and Claude Agent SDK runners are tracked (help-wanted issue #36 if you want to build one).

I wrote a head-to-head with promptfoo (where it wins vs where eval-harness wins): https://github.com/nano-step/eval-harness/blob/main/docs/why-not-promptfoo.md

And a concepts page on the 4 ideas above: https://github.com/nano-step/eval-harness/blob/main/docs/concepts.md

Happy to answer questions about why I picked bash, why 4 attribution classes and not 3 or 5, how flaky-detection composes with attribution, or anything else. Honest feedback welcome — I'm especially looking for edge cases where the attribution decision tree is wrong.
```

---

## Response playbook for the comments thread

You will get ~3 kinds of comments. Prepare answers in advance.

### Kind 1: "Why bash? Why not Python/TypeScript?"

> Two reasons. (1) The bar to install is `npm i -g` + `apt install jq`. No venv, no asdf, no Docker. People actually run it. (2) The harness has to spawn opencode/LangGraph/whatever as a subprocess anyway — bash is the right glue language for "spawn things, capture transcripts, compute SHAs." I wrote the first Python version. It was longer and had more failure modes.

### Kind 2: "How is this different from promptfoo?"

Point at https://github.com/nano-step/eval-harness/blob/main/docs/why-not-promptfoo.md . Don't re-explain in the thread; let the doc do the work. Two sentences summary: "promptfoo is a great _eval framework_ — datasets, scenarios, redteam. eval-harness is a focused _regression-detection harness_ — attribution, flaky, $-gating. They compose."

### Kind 3: "Why opencode-only? My agents are in [other framework]"

> Honestly: because that's what I ship. The runner contract is a small seam (4 subcommands, ~150 lines of bash). LangGraph runner is help-wanted issue #36 — if you ship a LangGraph agent and want regression testing on it, that PR is the highest-leverage contribution you can make. Happy to mentor.

### Kind 4 (hostile): "You're reinventing X / This is a wrapper around Y / Snake oil"

Don't defend. Acknowledge + redirect.

> Fair — the deterministic pieces (shell checks, jq paths, file_exists) are not novel. The contribution is the **combination**: 6-field FAIL + 4-class attribution + 3-sample stability + $-gating, all in one tool with hooks already wired. If that combination is wrong for you, promptfoo or DeepEval are good alternatives — I link both in the docs.

### What NOT to do

- Don't argue. HN comments train you for snark and you'll lose points.
- Don't pile on the second post in 48 hours if the first flops. Wait 6 months.
- Don't comment from sockpuppet accounts. HN admins WILL find them and you'll get nuked.
- Don't ask friends to upvote. Same.

## After the post

- First 2 hours determine front page or not.
- Watch the rank delta. If you're not on front page by hour 4, you won't get there.
- Even a 30-upvote post that doesn't reach front page is worth 20-50 stars from the people who scrolled past.
- Star count is the lagging indicator. Watch GitHub Insights → Traffic for **referrers**. HN clicks show up as `news.ycombinator.com` for ~72 hours.
- Reply to every substantive comment within 1 hour during the first 4 hours. After that, every 2-3 hours is fine.
