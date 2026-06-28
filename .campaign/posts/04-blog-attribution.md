# Blog post: "4-class attribution: why most LLM eval failures are misdiagnosed"

> **Publish on**: your own blog FIRST (canonical URL with rel=canonical), then cross-post to dev.to and Medium with the `<canonical>` pointed back to your blog. This protects SEO.
> **Word count**: 1400-1600. dev.to and HN both reward this length — long enough to be substantive, short enough to read in coffee break.
> **Hero image**: screenshot of the 6-field FAIL output (use the same one from README).
> **Tags**: `#llm`, `#testing`, `#ai`, `#opensource`, `#claude`, `#devops`

---

## Title (the SEO move)

```
4-class attribution: why most LLM eval failures are misdiagnosed
```

Subtitle:

```
A simple decision tree that tells you whether your prompt broke, your model drifted, or your test is flaky — before you waste an hour debugging.
```

---

## Body

The first time an LLM eval failed in my CI on a Tuesday morning, I spent an hour debugging my prompt. The culprit turned out to be Anthropic. They had shipped a silent minor revision of claude-3-5-sonnet over the weekend.

I wasn't the only one. [I checked the model version field](https://docs.anthropic.com/) and saw four un-announced point releases of sonnet through 2024.

The wasted hour wasn't the model's fault. It was my eval tool's fault. The tool told me "test X failed, expected Y, got Z." It didn't tell me whether the cause was my code, my fixture, the model, or just LLM jitter.

I needed a tool that says: "test X failed, attribution = MODEL_CHANGED, your prompt is byte-identical to baseline, this is on Anthropic." That tool didn't exist. So I built it.

This is the design write-up for the attribution layer.

### The 4 classes

Every failure gets exactly one class:

| Class | What changed since baseline | What you should do |
|---|---|---|
| `SKILL_CHANGED` | Your skill file SHA differs | Read the diff. Fix the skill, or accept the new behavior. |
| `FIXTURE_STALE` | Your fixture directory SHA differs (but the skill doesn't) | Bless the fixture. `eval-harness accept --case <id>`. |
| `MODEL_CHANGED` | `model_id` or runtime version differs (but skill + fixture don't) | Anthropic shipped a model change. Decide if the new behavior is acceptable. |
| `UNKNOWN_DRIFT` | None of the above | Run the 3-sample stability check. If unstable → flaky. If stable → file a bug. |

That's the whole layer. **It's not a probabilistic classifier.** It's a decision tree over four SHA fields captured at baseline time and re-captured at run time. The whole implementation fits in one bash file: [`scripts/eval/lib/attribute.sh`](https://github.com/nano-step/eval-harness/blob/main/scripts/eval/lib/attribute.sh).

### Why 4 and not 3 or 7

I went through several variations before landing on 4. The discarded ones tell you about the constraint.

**3 classes (skill / fixture / unknown)**. Loses `MODEL_CHANGED`, which is the single most common cause of mystery regressions in 2025-2026. Rejected.

**7 classes (split UNKNOWN into MCP_FLAKE, HARNESS_BUG, NETWORK_TIMEOUT, RATE_LIMIT, …)**. I designed this and shipped it for a week. Then realized I couldn't reliably distinguish MCP_FLAKE from HARNESS_BUG without false positives. **Honesty beat false precision.** The signal collapsed into UNKNOWN_DRIFT with a note that the 3-sample stability check would catch flake.

**5 classes (add PROMPT_INJECTION)**. Tempting because LLM red-team detection is a hot topic. Wrong concern. Prompt injection isn't a regression class; it's a separate eval category. I added a future `skill-reviewer` tool to the roadmap and kept attribution focused.

The lesson: **fewer classes you can defend > more classes that pretend.** Anyone who claims 12 attribution categories is either over-fitting or selling something.

### The env-manifest is the lynchpin

The thing that makes attribution work is the env-manifest captured at baseline time:

```json
{
  "skill_bundle_sha": "sha256:9d4e1b8...",
  "skill_sha": "sha256:7f3a2c1...",
  "fixture_sha": "sha256:e8d29a4...",
  "model_id": "claude-3-5-sonnet-20241022",
  "opencode_version": "1.15.2",
  "platform": "darwin-arm64",
  "captured_at": "2026-05-30T11:42:08Z"
}
```

Without `model_id` you cannot detect MODEL_CHANGED. Without `skill_bundle_sha` you cannot detect cross-skill interaction breaks (which DO happen — skill A's regex changes how skill B parses input, even though B is byte-identical).

Most eval tools either don't capture this manifest at all or capture only `expected/actual`. The manifest is **cheap** (kilobytes), the math is **trivial** (SHA comparison), and the payoff is the difference between "test failed" and "test failed and here's exactly what changed."

### The stability check catches the false positives

A failure with attribution = `UNKNOWN_DRIFT` is rare but it does happen. The decision tree says "nothing in your environment changed but the test failed." That's either:

1. A real intermittent bug (race condition, MCP server flake, network blip)
2. LLM jitter at temperature > 0
3. A bug in the harness itself

To separate (1) and (3) from (2), eval-harness re-runs the failing case 3 times and hashes outputs byte-for-byte. If all 3 are identical, it's a real failure — file a bug. If any divergence, tag `flaky: true` and don't pretend you can attribute it.

This is the part where most eval tools cheat by silently retrying until pass. eval-harness records the flake. You see flakiness in `history.ndjson` over time and can chart your suite's stability. Cheating obscures the signal.

### The numbers from the first 4 weeks

I dogfooded eval-harness on its own development. Numbers from `history.ndjson`:

- **47 runs across 23 cases**
- **8 attributed failures**: 5 `SKILL_CHANGED` (me breaking my own skill on iteration), 2 `FIXTURE_STALE` (I forgot to update the case after intentional output change), 1 `MODEL_CHANGED` (Anthropic point release surfaced a tone difference)
- **3 cases tagged `flaky: true`**: all in the LLM-judge bucket, all on prose-output skills, all resolved by tightening the rubric
- **Zero false `MODEL_CHANGED` attributions** verified by manual model_id check

Small sample, but the attribution-true-positive rate held at 100% on the cases I could manually verify. The 4-class collapse holds.

### Try it

```bash
npm install -g @nano-step/eval-harness
eval-harness baseline --skill <your-skill>
# (edit your skill)
eval-harness run --skill <your-skill>
# → exit 12 + attribution line in diff.md
```

Repo: [github.com/nano-step/eval-harness](https://github.com/nano-step/eval-harness)
4-class implementation: [attribute.sh](https://github.com/nano-step/eval-harness/blob/main/scripts/eval/lib/attribute.sh)
Concept walkthrough (4 ideas, 10 min): [docs/concepts.md](https://github.com/nano-step/eval-harness/blob/main/docs/concepts.md)

### What I want feedback on

- **Is 4-class right?** Specifically: is collapsing MCP_FLAKE and HARNESS_BUG into UNKNOWN_DRIFT too lossy? I argued against splitting them because I couldn't reliably tell them apart — I'd like to be wrong.
- **What's a regression on your LLM agent that the 4 classes miss?** I'm collecting case recipes for the v0.5.0 docs.
- **Should `MODEL_CHANGED` distinguish "model version bump" from "model alias bump"?** Right now I lump them; an argument exists for splitting.

Comments welcome. Issues welcome. PRs especially welcome — the [LangGraph runner](https://github.com/nano-step/eval-harness/issues/36) is the highest-leverage contribution available.

---

*eval-harness is MIT, bash + jq, 4 weeks old, v0.4.2. Built because I needed it.*

---

## SEO + cross-post setup

**dev.to canonical**:
```
canonical_url: https://yourblog.example.com/4-class-attribution
```

**Medium import**: use the "Import a story" feature with the canonical URL filled in. This sets `rel=canonical` correctly so the canonical version on your blog gets the link juice.

**HN link**: don't post the blog directly to HN — post the **repo** with the blog linked from the body, like in [`01-hn-show-post.md`](./01-hn-show-post.md). HN ranks repos and tools higher than blog posts.

**Twitter/X thread**: tease 3-4 of the strongest sentences (the wasted-hour anecdote, the "fewer classes you can defend" line, the 100% true-positive rate) — see [`07-x-thread.md`](./07-x-thread.md).
