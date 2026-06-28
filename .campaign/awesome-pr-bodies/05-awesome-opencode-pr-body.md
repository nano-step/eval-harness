## eval-harness

Behavior-regression testing harness for OpenCode skills.

**GitHub:** https://github.com/nano-step/eval-harness

### What it does

When you change an OpenCode skill, eval-harness detects whether the behavior has regressed, attributes the cause, and tells you exactly what changed.

- **4-class attribution** — skill change / fixture stale / model change / unknown drift (deterministic decision tree)
- **6-field FAIL schema** — `failed_check_id`, `expected`, `actual`, `diff_hint`, `transcript_span`, `env_delta`
- **3-sample stability check** — first-class flake tagging (`flaky: true`) instead of silent retry-until-pass
- **$ cost hard ceiling** — `EVAL_BUDGET_USD` env var, per-run enforcement
- **Composite GitHub Action** at `.github/actions/eval-harness/`
- **Git pre-push hook** — runs cases on `git push` and blocks on real FAIL
- **Bash + jq + python3 stdlib** — no daemon, no SaaS, no Node

### Why this fits `data/projects/`

Not a plugin, not a theme, not an agent, not a resource. eval-harness is a standalone tool that ships with an OpenCode runner as one of its supported runner backends. It composes with the OpenCode skills ecosystem — anyone maintaining an OpenCode skill can drop eval-harness into their repo and get regression detection on every push.

### Honest scope

- **Status:** v0.4.2 (released 2026-05-30), 20/20 test suites green on `main`
- **License:** MIT
- **Traction:** new project (~4 weeks old). Stays honest in the PR body.
- **Prior art in this list:** none — eval-harness is the only regression-detection harness that ships with an OpenCode runner.

### Category

Fits `data/projects/` per the [contributing guide](https://github.com/awesome-opencode/awesome-opencode/blob/main/contributing.md).

### Checklist

- [x] Relevant to OpenCode (ships an OpenCode runner; integrates via git pre-push hook)
- [x] Public repository: https://github.com/nano-step/eval-harness
- [x] Active (v0.4.2 released 2026-05-30; commits within last 30 days)
- [x] Unique (no existing entry for behavior-regression testing in this list)
- [x] YAML complete with all required fields (`name`, `repo`, `tagline`, `description`)
- [x] Description fits the long-form blockquote in the rendered README

Thanks for maintaining the list.
