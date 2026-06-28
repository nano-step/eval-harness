# PR: tensorchord/Awesome-LLMOps

> **Submit today.** 5.8k stars, very active (last merge 2026-05-17), accepts author PRs.
> **Repo URL**: https://github.com/tensorchord/Awesome-LLMOps
> **Target section**: `## LLMOps` (we provide CI gating + regression detection; that's LLMOps testing infra)

## Pre-flight

```bash
# Activity check (verify recent merges)
gh pr list -R tensorchord/Awesome-LLMOps --state merged --limit 5 --json createdAt --jq '.[].createdAt'

# Read CONTRIBUTING if present
gh api repos/tensorchord/Awesome-LLMOps/contents/CONTRIBUTING.md -H "Accept: application/vnd.github.raw" 2>/dev/null || echo "(no CONTRIBUTING.md)"
```

## Step 1 — fork + branch

```bash
gh repo fork tensorchord/Awesome-LLMOps --org nano-step --clone --remote
cd Awesome-LLMOps
git checkout -b add-eval-harness
```

## Step 2 — find the right section in README.md

Sections in this list:
- `## LLMOps` ← us
- `## Serving` (no)
- `## Optimizations` (no)
- `## Performance` (no — though we have $-gating)
- `## Security` (no)

LLMOps section sub-areas: training, deployment, monitoring, observability, testing. Place under testing / evaluation if a sub-bucket exists.

## Step 3 — find a neighbor entry to match style

Look at how entries near alphabetical "e" look. The list typically uses:

```markdown
* [Name](url) - Description
```

Or:

```markdown
* [Name](url) ![GitHub Repo stars](https://img.shields.io/github/stars/owner/repo?style=social) — Description.
```

Match neighbors exactly.

## Step 4 — insert the entry

```markdown
* [eval-harness](https://github.com/nano-step/eval-harness) ![GitHub Repo stars](https://img.shields.io/github/stars/nano-step/eval-harness?style=social) — Behavior-regression testing for LLM agents. 4-class attribution, 6-field FAIL schema, $-cost gating, flaky detection. Bash + jq, MIT.
```

Alphabetical position: between `eval-` (if any) and `ev*` neighbors. Verify in diff.

## Step 5 — PR

```bash
git add README.md
git commit -s -m "Add eval-harness to LLMOps"
git push origin add-eval-harness

gh pr create --repo tensorchord/Awesome-LLMOps \
  --base main \
  --head nano-step:add-eval-harness \
  --title "Add eval-harness to LLMOps section" \
  --body "$(cat .campaign/awesome-pr-bodies/02-awesome-llmops-pr-body.md)"
```

## PR body

```markdown
## Adding eval-harness to the LLMOps section

**Project**: https://github.com/nano-step/eval-harness
**License**: MIT
**Language**: Bash (+ jq, python3 stdlib)
**Released**: v0.4.2 on 2026-05-30

## What it does

Behavior-regression testing for LLM agents — detects when an agent drifts from baseline, attributes the cause across 4 deterministic classes (SKILL_CHANGED / FIXTURE_STALE / MODEL_CHANGED / UNKNOWN_DRIFT), and emits a 6-field FAIL schema. Ships a composite GitHub Action and git pre-push hook.

## Why this fits LLMOps

LLMOps testing/observability is a known gap: existing tools tell you THAT a test failed but not WHY. eval-harness fills the regression-detection + attribution slice with:

- 4-class failure attribution (deterministic SHA-comparison decision tree)
- 6-field FAIL schema with `transcript_span` + `env_delta`
- 3-sample byte-identical stability check (first-class flake tagging, not retry-until-pass)
- Hard $-cost ceiling with daily budget enforcement
- Per-(case,trigger) flock lockfile for safe concurrent CI runs

## Distinctive vs other LLMOps entries

This list already has strong eval/observability entries (promptfoo, LangSmith, Phoenix, etc.). eval-harness occupies a narrower slice — **focused on regression detection with attribution**. It composes with broader tools rather than replacing them. Head-to-head with promptfoo: [docs/why-not-promptfoo.md](https://github.com/nano-step/eval-harness/blob/main/docs/why-not-promptfoo.md).

## Project hygiene

- [x] MIT licensed, MIT-only deps (jq, python3 stdlib)
- [x] CONTRIBUTING.md + CODE_OF_CONDUCT.md + SECURITY.md
- [x] 20/20 test suites green on `main` (including GNU/BSD grep portability + fixture path-traversal hardening)
- [x] DCO sign-off on commit
- [x] Active maintenance (v0.4.2 shipped 2 days ago, closed 8 audit BLOCKERs)
- [x] Open `good first issue` + `help wanted` labels for contributors
- [x] Entry placed alphabetically (verify in diff)

## Honest scope

eval-harness is NOT a general LLM eval framework, NOT a quality grader, NOT a prompt engineer. It is a focused regression-detection harness. We document this scope explicitly: [README scope statement](https://github.com/nano-step/eval-harness#scope-statement).

Thank you for maintaining this list — it's the canonical reference for LLMOps tooling.
```
