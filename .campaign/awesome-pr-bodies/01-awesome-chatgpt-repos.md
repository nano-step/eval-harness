# PR: taishi-i/awesome-ChatGPT-repositories

> **Submit today.** No star floor. Largest LLM-tooling awesome list at ~2k stars itself.
> **Repo URL**: https://github.com/taishi-i/awesome-ChatGPT-repositories

## Step 1 — fork + clone

```bash
gh repo fork taishi-i/awesome-ChatGPT-repositories --org nano-step --clone --remote
cd awesome-ChatGPT-repositories
git checkout -b add-eval-harness
```

## Step 2 — find the right section

Open `README.md`. Look for either:
- `## Testing` or `## Evaluation` — preferred
- `## Tools` — fallback

The maintainer organizes by Japanese + English. Insert in the English subsection only.

## Step 3 — add the line (match neighbor style)

Sample neighbor format from the existing list:

```markdown
- [project-name](https://github.com/owner/repo) - Short description.
```

So the entry becomes:

```markdown
- [eval-harness](https://github.com/nano-step/eval-harness) - Behavior-regression testing for LLM agents. 4-class attribution, 6-field FAIL schema, $-cost gating, flaky detection. Bash + jq, MIT.
```

**Alphabetical position**: place after `eth-` entries and before `evals` (`OpenAI Evals`).

## Step 4 — commit + push + PR

```bash
git add README.md
git commit -m "Add eval-harness — behavior-regression testing for LLM agents"
git push origin add-eval-harness

gh pr create --repo taishi-i/awesome-ChatGPT-repositories \
  --base main \
  --head nano-step:add-eval-harness \
  --title "Add eval-harness — behavior-regression testing for LLM agents" \
  --body "$(cat .campaign/awesome-pr-bodies/01-awesome-chatgpt-repos-pr-body.md)"
```

## PR body (save as `01-awesome-chatgpt-repos-pr-body.md` before running gh pr create)

```markdown
## Adding eval-harness to the testing/evaluation section

**Project**: https://github.com/nano-step/eval-harness
**License**: MIT  
**Language**: Bash (+ jq, python3 stdlib)  
**Released**: v0.1 on 2026-05-04, v0.4.2 on 2026-05-30

## What it does

Behavior-regression testing for LLM agents — detects when an agent's behavior drifts from a baseline, attributes the cause across 4 deterministic classes (SKILL_CHANGED / FIXTURE_STALE / MODEL_CHANGED / UNKNOWN_DRIFT), and emits a 6-field FAIL schema with `transcript_span` + `env_delta` evidence.

Ships a git pre-push hook and a composite GitHub Action.

## Distinctive features vs other entries on the list

- 4-class failure attribution (no other entry on this list does this)
- 6-field FAIL schema (most tools emit only expected/actual)
- 3-sample byte-identical stability check — first-class flake tagging instead of retry-until-pass
- Hard $-cost ceiling with persistent daily budget
- No daemon, no Node CLI, no SaaS — bash + jq + python3 stdlib

## Honest scope

eval-harness is a focused regression-detection harness, not a general LLM eval framework. It composes with broader tools like promptfoo (head-to-head comparison: [docs/why-not-promptfoo.md](https://github.com/nano-step/eval-harness/blob/main/docs/why-not-promptfoo.md)).

## Project hygiene

- [x] README with installation + 5-min quickstart
- [x] CONTRIBUTING.md + CODE_OF_CONDUCT.md + SECURITY.md
- [x] 20/20 test suites green on `main` (including GNU/BSD grep portability + path-traversal hardening)
- [x] Open issues with `good first issue` and `help wanted` labels for contributors
- [x] Entry placed alphabetically (please verify in diff)

Thanks for maintaining this excellent list.
```
