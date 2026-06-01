# eval-harness GitHub Action

[![marketplace](https://img.shields.io/badge/Marketplace-eval--harness-blue?logo=github)](https://github.com/marketplace/actions/eval-harness)

Behavior-regression testing for LLM agents — runs `@nano-step/eval-harness` against any opencode skill in your repo and gates the PR/push on the result.

## Quick start

Drop this in `.github/workflows/eval.yml`:

```yaml
name: eval
on:
  pull_request:
    paths: [".opencode/skills/**"]
  push:
    branches: [main]
    paths: [".opencode/skills/**"]

jobs:
  eval:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0  # required for diff-based skill detection
      - uses: nano-step/eval-harness/.github/actions/eval-harness@v0.4.2
        with:
          all-changed: true
          mode: 2tier
          budget-usd: "1.00"
          anthropic-api-key: ${{ secrets.ANTHROPIC_API_KEY }}
          fail-on-regression: true
```

That's the full integration. The action will:

1. Install `jq`, `yq`, `opencode`, `@nano-step/eval-harness`
2. Detect which skills changed in this PR / push
3. Run each affected skill through eval-harness in 2-tier mode (cheap smoke, escalate to full on FAIL)
4. Post a job summary with verdict + attribution + 6-field FAIL detail
5. Upload `runs/` as a workflow artifact
6. Exit 12 if regression detected (fails the check)

## Inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `skill` | one of | — | Specific skill name to evaluate |
| `all-changed` | one of | `false` | Auto-detect changed skills from the diff |
| `mode` | no | `2tier` | `smoke` \| `full` \| `2tier` |
| `budget-usd` | no | `2.00` | Daily $ cost ceiling (`EVAL_BUDGET_USD`) |
| `fail-on-regression` | no | `true` | Whether to exit 12 (and fail the check) on regression. Set `false` for warn-only. |
| `anthropic-api-key` | only if any case uses `kind: llm_judge` | — | Anthropic API key |
| `opencode-version` | no | `latest` | opencode CLI version to install |
| `eval-harness-version` | no | `latest` | `@nano-step/eval-harness` version |

You must set **exactly one** of `skill` or `all-changed`.

## Outputs

| Output | Description |
|---|---|
| `verdict` | `PASS` \| `REGRESSION` \| `FLAKY` \| `HARNESS_ERROR` |
| `attribution` | On regression: `SKILL_CHANGED` \| `FIXTURE_STALE` \| `MODEL_CHANGED` \| `UNKNOWN_DRIFT` |
| `total-cost-usd` | Total $ cost of the eval run |
| `report-path` | Filesystem path to `diff.md` |

## Examples

### Warn-only (don't block the PR yet)

```yaml
- uses: nano-step/eval-harness/.github/actions/eval-harness@v0.4.2
  with:
    all-changed: true
    fail-on-regression: false
```

### Specific skill, full mode, custom budget

```yaml
- uses: nano-step/eval-harness/.github/actions/eval-harness@v0.4.2
  with:
    skill: customer-support-agent
    mode: full
    budget-usd: "5.00"
    anthropic-api-key: ${{ secrets.ANTHROPIC_API_KEY }}
```

### Use the result downstream

```yaml
- id: eval
  uses: nano-step/eval-harness/.github/actions/eval-harness@v0.4.2
  with:
    all-changed: true
    fail-on-regression: false
    anthropic-api-key: ${{ secrets.ANTHROPIC_API_KEY }}

- name: Comment on PR
  if: ${{ steps.eval.outputs.verdict == 'REGRESSION' }}
  uses: actions/github-script@v7
  with:
    script: |
      github.rest.issues.createComment({
        owner: context.repo.owner,
        repo: context.repo.repo,
        issue_number: context.issue.number,
        body: `eval-harness detected a regression: \`${{ steps.eval.outputs.attribution }}\` ($${{ steps.eval.outputs.total-cost-usd }}). See [job summary](${context.serverUrl}/${context.repo.owner}/${context.repo.repo}/actions/runs/${context.runId}).`
      })
```

## Pinning

Pin to a specific version for reproducible CI:

```yaml
- uses: nano-step/eval-harness/.github/actions/eval-harness@v0.4.2
```

Or pin to a SHA for maximum guarantees:

```yaml
- uses: nano-step/eval-harness/.github/actions/eval-harness@<commit-sha>
```

## Limitations

- Composite action, runs on Linux only (will likely work on macOS runners, untested).
- Requires `actions/checkout@v4` with `fetch-depth: 0` when `all-changed: true`.
- LLM-judge cases require `ANTHROPIC_API_KEY` — without it, those cases are skipped with a warning.
- Pricing data ships per release; if you stay on an old release for > 60 days the harness will warn about stale pricing.

## Marketplace listing

To publish as a marketplace action: create a release with tag `v0.4.2` (or current version), then visit https://github.com/nano-step/eval-harness/releases — GitHub will offer a "Publish this release to the Marketplace" toggle. The action is composite (no Dockerfile), so no extra infra needed.
