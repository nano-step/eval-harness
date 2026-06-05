# PR: awesome-opencode/awesome-opencode

> **Submit today.** Active maintainer activity, 7,630★ list, opencode ecosystem — highest fit of any list. Same author already has PR #387 ("docs: add iamhumans") open here, so maintainer will see the pattern.

> **Repo URL**: https://github.com/awesome-opencode/awesome-opencode

## IMPORTANT: YAML workflow (NOT README.md)

This list is **YAML-driven**. Do NOT edit `README.md` — it's auto-generated.

Per `contributing.md`:
- Add a YAML file under `data/<category>/<name>.yaml`
- Categories: `plugins/`, `themes/`, `agents/`, `projects/`, `resources/`
- Required fields: `name`, `repo`, `tagline` (max 120 chars), `description`
- Optional: `homepage`, `tags` (list of strings)
- Filename: kebab-case
- PR title format: `docs: add <name> to <category>`

## Category for eval-harness

**`data/projects/`** — eval-harness is a standalone tool that ships an OpenCode runner as one of its supported runner backends. Not a plugin (doesn't extend opencode at runtime), not a theme, not an agent, not a resource.

## Step 1 — fork + clone + branch

```bash
gh repo fork awesome-opencode/awesome-opencode --org nano-step --clone
cd awesome-opencode
git remote add upstream https://github.com/awesome-opencode/awesome-opencode.git
git fetch upstream main
git checkout -b add-eval-harness
```

## Step 2 — create the YAML

`data/projects/eval-harness.yaml`:

```yaml
name: eval-harness
repo: https://github.com/nano-step/eval-harness
tagline: Behavior-regression testing for OpenCode skills
description: Detects when an OpenCode skill's behavior drifts from a baseline, attributes the cause across 4 classes (skill change / fixture stale / model change / unknown drift), and emits a 6-field FAIL schema with transcript-span and env-delta evidence. Ships a git pre-push hook, a composite GitHub Action, and a $-cost hard ceiling for CI safety. Bash + jq + python3 stdlib only; no daemon, no SaaS. MIT.
```

## Step 3 — commit + push + PR

```bash
git add data/projects/eval-harness.yaml
git commit -m "docs: add eval-harness to projects"
git push -u origin add-eval-harness

gh pr create --repo awesome-opencode/awesome-opencode \
  --base main \
  --head nano-step:add-eval-harness \
  --title "docs: add eval-harness to projects — behavior-regression testing for OpenCode skills" \
  --body-file .campaign/awesome-pr-bodies/05-awesome-opencode-pr-body.md
```

## PR body

See `05-awesome-opencode-pr-body.md` in this directory.

## Why this list is high-fit

- **Activity**: pushed 2026-03-21; many recent merged PRs (e.g. #401 opentelemetry plugin merged)
- **Size**: 7,630★, 198 open issues
- **Pattern**: ~all PRs follow `docs: add <name> to <category>` title format
- **Prior context**: hoainho's PR #387 (iamhumans) already open — maintainer recognizes the author
- **Auto-validation**: list runs YAML validation in CI; format errors get caught before maintainer review

## Reusable at 100/500/1000 stars

- Same PR pattern (just update tagline/description)
- Maintainer cadence: ~3-5 PRs merged per week
- Reasonable expectation: merged within 1-2 weeks of opening
