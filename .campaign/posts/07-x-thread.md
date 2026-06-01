# X/Twitter thread (8 tweets)

> **Post under**: the maintainer account ([@hoainho_dev](https://x.com/) or whichever handle).
> **Best time**: Tuesday 14:00 UTC (9am ET) or 22:00 UTC (5pm ET).
> **Pin the first tweet** for a week after posting.
> **Engage**: reply to every comment in the first 4 hours. After that, drop to "respond to substantive only."

---

## Tweet 1 (hook, 280 char max)

```
Last Tuesday a CI test on my LLM agent failed.

I spent 25 minutes blaming my prompt.

The actual culprit: Anthropic shipped a silent point release of claude-3-5-sonnet over the weekend.

That wasted 25 minutes is why I built eval-harness 👇

🧵 (1/8)
```

(no link in tweet 1 — preserves algorithm reach. Link in tweet 8.)

## Tweet 2

```
Most LLM eval tools tell you THAT a test failed.

They give you `expected` and `actual`.

They don't tell you whether the cause was:
- your prompt edit
- a stale fixture
- the model upgrading under you
- or just LLM jitter

eval-harness does. 4 classes. Deterministic. (2/8)
```

## Tweet 3

```
The 4 attribution classes:

▸ SKILL_CHANGED → your prompt diff
▸ FIXTURE_STALE → your test data drifted
▸ MODEL_CHANGED → Anthropic shipped under you
▸ UNKNOWN_DRIFT → falls through to 3-sample stability check

It's a SHA-comparison decision tree. No ML. ~40 lines of bash. (3/8)
```

## Tweet 4

```
The FAIL output is 6 fields, not 2:

failed_check_id
expected
actual
diff_hint        ← one-sentence narrowing
transcript_span  ← line range in agent's transcript
env_delta        ← what changed since baseline

The last two are the killers. Most tools skip them. (4/8)
```

## Tweet 5

```
"Just retry until pass" is the standard CI mitigation for flaky LLM tests.

It's wrong. Hides real intermittent bugs.

eval-harness re-runs FAILing cases 3× and hashes outputs byte-for-byte:

▸ all 3 identical → real FAIL, attribute it
▸ any divergence → tag `flaky: true`, don't pretend

(5/8)
```

## Tweet 6

```
$-cost hard ceiling.

EVAL_BUDGET_USD=2.00 (default). When you blow $2 in a day, harness aborts before the next call.

Single biggest reason teams turn off LLM eval in CI = "it costs too much."

Hard cap fixes that. No surprise Anthropic invoices on Monday morning. (6/8)
```

## Tweet 7

```
What it is:
▸ bash + jq + python3 stdlib
▸ no daemon, no Node CLI, no SaaS
▸ MIT
▸ git pre-push hook + GitHub Action shipped
▸ 20/20 test suites green
▸ v0.4.2

What it isn't:
▸ a quality grader
▸ a prompt-engineering AI
▸ a skill-design reviewer
▸ cloud-anything (7/8)
```

## Tweet 8 (CTA + link)

```
Try it on a skill you ship today:

npm i -g @nano-step/eval-harness
eval-harness baseline --skill <name>
# (edit your skill)
eval-harness run --skill <name>

Repo: github.com/nano-step/eval-harness

Comparison vs promptfoo / DeepEval honest write-up in /docs.

⭐ if useful. PRs welcome (LangGraph runner is help-wanted). (8/8)
```

---

## Reply playbook

**If quote-tweeted with "this is just X with extra steps"**:
> Possibly fair. The novel part isn't any single piece — it's the combination of (4-class attribution + 6-field FAIL + 3-sample stability + $-gating) all in one tool with hooks already wired. If you've seen the combination shipped elsewhere, link it — I'll credit + borrow what I can.

**If quote-tweeted with "why bash"**:
> The harness has to spawn an agent subprocess and capture transcripts regardless of language. Bash is the right glue for that. I wrote the Python version first. It was longer and had more failure modes.

**If quote-tweeted with promptfoo comparison**:
> Different problems. promptfoo = great eval framework (datasets, scenarios, redteam). eval-harness = focused regression-detection (attribution, flaky, $-gate). They compose — many teams will run both. Wrote a direct head-to-head here: https://github.com/nano-step/eval-harness/blob/main/docs/why-not-promptfoo.md

**If someone genuinely engages on the technique** (e.g. "what about pass@k vs your 3-sample"):
Reply in 1-2 tweets with substance. Don't link out unless they ask. Convert the conversation into Discussion #28 if it goes long.

**If someone asks for LangGraph / CrewAI / X support**:
> Today: opencode-only runner shipped. The runner contract is small (4 subcommands, ~150 lines of bash). LangGraph runner is help-wanted issue #36 — if you want it AND you ship a LangGraph agent, that PR is the highest-leverage contribution available right now. I'll mentor.

## What NOT to do on X

- ❌ Don't beg for retweets. Algorithm punishes it.
- ❌ Don't reply with emoji-only.
- ❌ Don't engagement-bait with "tag a friend who needs this."
- ❌ Don't tag big accounts (e.g. @AnthropicAI) unless they're actually relevant — tag-spam is detected.
- ❌ Don't post the same thread twice if the first flops. Wait 2 weeks, rewrite from a different angle.
- ✅ DO reply to your own thread once with a "+1 found bug X via attribution" update after a week. Bumps the thread without spamming.
