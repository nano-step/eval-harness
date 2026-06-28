# Blog post: "The 6-field FAIL schema (and why your eval tool's FAIL is useless)"

> **Audience**: developers who've used promptfoo / DeepEval / Ragas and felt the "test failed but I have no idea why" pain.
> **Word count**: 1100-1300.
> **Stance**: opinionated, specific. Not balanced. People remember a strong take.

---

## Title

```
The 6-field FAIL schema (and why your eval tool's FAIL is useless)
```

## Subtitle

```
"Expected X, got Y" is not enough. Here are the four fields your eval tool isn't giving you, and what each one saves.
```

---

## Body

I ran an LLM regression test last Tuesday. It failed.

The output was:

```
✗ output_contains: did not find "architecture"
  received: "Yes, I can help with that. Could you tell me more..."
```

Useful: I know `architecture` didn't appear.
**Not useful**: where in the transcript the missing word should have been. What other words were there. Whether the skill changed since baseline. Whether the model changed. Whether retrying would pass.

I spent 25 minutes on git blame, ran the test 3 more times manually, eventually narrowed it to a 2-line prompt edit from yesterday. Then I deleted the eval tool and wrote one with a 6-field FAIL schema.

This post is what the 6 fields are, why each one earned its place, and what I dropped.

### The schema

Every FAIL is recorded as exactly these fields. Verbatim from `diff.md`:

```yaml
failed_check_id:    atom-tags-decision-architecture
expected:           $.atoms[].tags[] contains "architecture"
actual:             ["redux", "redaction"]
diff_hint:          tag "architecture" missing from atom #2
transcript_span:    lines 142-158 of opencode.log
env_delta:          skill_sha 7f3a2c1 → 9d4e1b8 (only delta)
```

Six fields. No more. Below: what each saves you.

### 1. `failed_check_id` — the grep handle

Stable identifier so you can grep history. `atom-tags-decision-architecture` is the same string in every run. You can chart how often it fails, when it started failing, whether it co-fails with other cases.

Most eval tools use a synthetic numeric ID that changes between runs. That makes "show me the test that broke last week" impossible without ad-hoc parsing.

**Saves**: history queries, regression-pattern detection.

### 2. `expected` — verbatim from YAML, not paraphrased

`$.atoms[].tags[] contains "architecture"` is the **literal text** from the case YAML. Not a paraphrase. Not a humanized version. The verbatim assertion.

Why this matters: when you're debugging the failure, you want to copy-paste the assertion into a REPL and reproduce the check manually. Paraphrased text wastes 5 minutes finding the original.

**Saves**: manual reproduction.

### 3. `actual` — structured, not stringified

`["redux", "redaction"]` is the actual array value extracted via the jq path. Not the whole LLM transcript. Not a serialized string.

When the check is structural (jq_path_contains, file_exists, output_contains), `actual` is the structural value. When the check is shell-based, `actual` is stdout. Match the **shape of the check** with the **shape of the actual**.

Most tools give you "the LLM output" verbatim, even when the check only cares about one slice of it. You then have to grep for the slice manually.

**Saves**: 30 seconds per FAIL × N FAILs × 12 weeks. Compounds.

### 4. `diff_hint` — one sentence narrowing the gap

`tag "architecture" missing from atom #2`

This is what most tools don't emit because it requires the harness to *understand* the check kind. It's just one sentence — but it's the one sentence that points your eyes at the right column of the right row.

For `kind: shell`, the diff_hint is the longest common substring difference. For `kind: jq_path_contains`, it's "value at $.foo[N] differs." For `kind: llm_judge`, it's the rubric sentence the judge marked unsatisfied.

Generated mechanically. No LLM call. Just a small lookup table per check kind.

**Saves**: cognitive load. You stop scanning expected/actual line-by-line.

### 5. `transcript_span` — the line range in the agent's log

`lines 142-158 of opencode.log`

This is the killer field. Every other tool gives you the LLM output as a blob. eval-harness tells you the **exact line range** in the agent transcript where the relevant output was emitted — so you can:

- Jump to those lines in your editor
- See what tool calls preceded the output
- See whether the agent reasoned its way to the wrong answer or panicked

For tool-use agents (Claude with tools, LangGraph nodes, opencode skills), the transcript_span includes the surrounding tool_use blocks. You learn *why* the LLM made the wrong call, not just *that* it did.

Implementation: when the runner writes the transcript, it records byte offsets per logical "message." When the check fails, the harness maps the check's matched range back to those offsets and emits the line range.

**Saves**: the "what was the model thinking" debug step. Often 10-15 minutes.

### 6. `env_delta` — what changed since baseline

`skill_sha 7f3a2c1 → 9d4e1b8 (only delta)`

This is the field that feeds [4-class attribution](https://yourblog.example.com/4-class-attribution). The env-manifest captures `skill_sha`, `skill_bundle_sha`, `fixture_sha`, `model_id`, `opencode_version`, `platform` at baseline time. At fail time, the harness computes the new manifest and emits the deltas.

`(only delta)` is the magic phrase. It means only one field changed. That's the attribution evidence.

If multiple fields changed (you edited the skill AND the fixture in the same commit), `env_delta` says so and attribution falls into `UNKNOWN_DRIFT` — honestly, because we can't tell which caused the failure.

**Saves**: the "is it me or the model" question. Often 30-60 minutes when you guess wrong.

### What I dropped

I considered several other fields and rejected them:

**`severity`** — every tool ships this. It's almost always wrong because "severity" is in the eye of the beholder. Replaced by per-case `--strict` opt-in (issue #10).

**`suggested_fix`** — I do generate fix_proposal as a separate enrichment field in the run output, but I deliberately keep it *out* of the 6-field FAIL because it's heuristic and shouldn't be confused with the deterministic evidence. fix_proposal goes in `diff.md`'s next section.

**`screenshots`** — N/A for text agents. Different tool.

**`stack_trace`** — only meaningful for harness errors, not case FAILs. Captured separately.

The 6 fields are the deterministic, useful evidence. Everything else is enrichment.

### Try it

```bash
npm install -g @nano-step/eval-harness
eval-harness baseline --skill <your-skill>
# break it
eval-harness run --skill <your-skill>
# → diff.md has the 6-field FAIL
```

Repo: [github.com/nano-step/eval-harness](https://github.com/nano-step/eval-harness)
6-field implementation: [`diff.sh`](https://github.com/nano-step/eval-harness/blob/main/scripts/eval/lib/diff.sh)

If your eval tool's FAIL doesn't have these 6 fields, you're paying for them out of your debug-time budget every week. Switch tools or open a PR upstream — but **stop accepting `expected/actual` as enough.**
