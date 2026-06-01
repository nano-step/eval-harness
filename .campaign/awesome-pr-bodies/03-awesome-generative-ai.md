# PR: steven2358/awesome-generative-ai

> **Submit today.** Soft ~50-star floor — borderline. Worth opening; honest rejection is fine if too early.
> **Repo URL**: https://github.com/steven2358/awesome-generative-ai

## Step 1 — fork + clone + branch

```bash
gh repo fork steven2358/awesome-generative-ai --org nano-step --clone --remote
cd awesome-generative-ai
git checkout -b add-eval-harness
```

## Step 2 — find the section

This list organizes by:
- Models (Image / Text / Code / Audio)
- Tools (Coding, Voice, Video editing, **Developer tools** ← us)
- Developer tools → **Evaluation** subsection if it exists

If no "Evaluation" subsection, the next best is "Developer tools" general bucket.

## Step 3 — add the line (match neighbors)

Their style is typically:

```markdown
- [eval-harness](https://github.com/nano-step/eval-harness) - Behavior-regression testing for LLM agents. 4-class attribution, 6-field FAIL schema. MIT.
```

Alphabetical placement within the subsection.

## Step 4 — PR

```bash
git add README.md
git commit -m "Add eval-harness — behavior-regression testing for LLM agents"
git push origin add-eval-harness

gh pr create --repo steven2358/awesome-generative-ai \
  --base main \
  --head nano-step:add-eval-harness \
  --title "Add eval-harness" \
  --body "$(cat .campaign/awesome-pr-bodies/03-awesome-generative-ai-pr-body.md)"
```

## PR body

```markdown
## Adding eval-harness to the Developer tools / Evaluation section

**Project**: https://github.com/nano-step/eval-harness
**License**: MIT
**Released**: v0.4.2 on 2026-05-30

## What it does

Behavior-regression testing for LLM agents — detects when an agent regresses since baseline, attributes the cause across 4 classes (skill / fixture / model / unknown), emits a 6-field FAIL schema. Ships a GitHub Action and git pre-push hook.

## Why this fits the list

Generative AI development needs regression detection that classical eval tools don't provide. Existing entries on the list cover prompt engineering and model fine-tuning; this fills the testing gap.

## Distinctive vs other entries

- 4-class attribution (deterministic, no other entry does this)
- 6-field FAIL with `transcript_span` + `env_delta`
- 3-sample stability check tags `flaky: true` instead of silently retrying
- $-cost hard ceiling for CI safety
- Bash + jq, no daemon, MIT

## Transparency on traction

This is a new project (v0.1 → v0.4.2 across 4 weeks). Star count is currently below the typical bar for this list. Opening the PR because the technical / scope / hygiene bars are met; I understand if you'd prefer to wait for traction. Happy to revisit at 100 / 250 / 500 stars whenever you say.

## Hygiene

- [x] MIT licensed
- [x] CONTRIBUTING.md + CODE_OF_CONDUCT.md + SECURITY.md
- [x] 20/20 test suites green
- [x] Alphabetical placement (verify in diff)

Thanks for the list.
```
