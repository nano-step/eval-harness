# Universal PR body template

> Adapt the below for each awesome-list submission. The PR-specific files reference this template.

---

## PR title

```
Add eval-harness — behavior-regression testing for LLM agents
```

## PR body

```markdown
## Adding @nano-step/eval-harness

**Project**: https://github.com/nano-step/eval-harness
**License**: MIT
**Language**: Bash (+ jq, python3 stdlib)
**Status**: v0.4.2 (released 2026-05-30), 20/20 test suites green on main

## What it does

Behavior-regression testing for LLM agents — detects when an agent's behavior drifts from a baseline, attributes the cause across 4 classes (skill / fixture / model / unknown), and emits a 6-field FAIL schema with deterministic evidence.

## Why this fits <SECTION_NAME>

<one paragraph tailored to the section's theme>

## Distinctive features

- **4-class failure attribution** (SKILL_CHANGED / FIXTURE_STALE / MODEL_CHANGED / UNKNOWN_DRIFT) — deterministic decision tree
- **6-field FAIL schema** with `transcript_span` + `env_delta` (not just expected/actual)
- **3-sample byte-identical stability check** — first-class flake tagging, not retry-until-pass
- **$-cost hard ceiling** with daily budget enforcement
- **Composite GitHub Action** + git pre-push hook shipped
- **No daemon, no SaaS** — bash + jq + python3 stdlib

## Honest scope

eval-harness is a **focused regression-detection harness**, not a general LLM eval framework. It composes with broader tools like promptfoo. We document a head-to-head comparison and a "when to use both" section: [docs/why-not-promptfoo.md](https://github.com/nano-step/eval-harness/blob/main/docs/why-not-promptfoo.md).

## Compliance with this list's guidelines

- [x] Project is published (released v0.1 on 2026-05-04, v0.4.2 on 2026-05-30)
- [x] Has a README with installation + quickstart
- [x] MIT licensed
- [x] CONTRIBUTING.md, CODE_OF_CONDUCT.md, SECURITY.md present
- [x] CI / tests visible — see `scripts/eval/tests/` (20 suites green)
- [x] Entry placed alphabetically within section (please verify in diff)

Thanks for maintaining this list.
```

---

## Per-list tweaks (read before opening any PR)

### For lists with strict CONTRIBUTING.md

Check whether the list:
- Requires DCO sign-off → `git commit -s`
- Requires the entry to be its own commit (not bundled with other changes)
- Has a PR title template (some require `Add: <name>` exactly)
- Has a self-promotion ban (e.g. some lists require a non-author to submit)

### Tone

Match each list maintainer's communication style. If their CONTRIBUTING.md is terse, your PR body should be terse. If they explicitly ask for honest scope statements, lead with the scope statement.

### Don't lie about stars

A few lists require a minimum star count (e.g. 100). At 4 stars, eval-harness fails several lists' bar today. **Be honest**: don't pretend. List the project on lists where it qualifies; revisit the others after Phase 3 traction.

Lists that work at 4 stars (no star floor or low floor):
- `taishi-i/awesome-ChatGPT-repositories` — no floor
- `e2b-dev/awesome-ai-agents` — no floor
- `steven2358/awesome-generative-ai` — soft 50-star floor

Lists that require waiting:
- `Hannibal046/Awesome-LLM` — informal ~500-star floor
- `visenger/awesome-mlops` — quality bar, no explicit floor but selective
- `tensorchord/Awesome-LLMOps` — informal floor

**Recommendation**: open PRs to the no-floor lists today. Revisit the others at 200 / 500 / 1000 stars.
