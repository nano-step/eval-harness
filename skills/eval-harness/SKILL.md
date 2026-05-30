---
name: eval-harness
description: Detects behavior regressions in opencode skills by running structured eval cases and comparing against committed baselines. Use whenever you say "run evals", "check regression", "baseline this skill", "did my skill regress", "did this prompt regress", "A/B these two skills" — or after editing any skill in `.opencode/skills/**`. Wires into `sync-skill-to-manager` as a pre-publish gate (opt-in per skill via `skill.yaml: evals.required`). Ships 4-class attribution (SKILL_CHANGED / FIXTURE_STALE / MODEL_CHANGED / UNKNOWN_DRIFT), 6-field FAIL diagnostics (failed_check_id, expected, actual, diff_hint, transcript_span, env_delta), and a one-command rerun affordance on every failure. v0.1.0 scope: structured-output skills only — prose-output skills (pr-code-reviewer, od-workflow, blog-workflow, idea-workflow) are deferred to v0.3 LLM-judge.
compatibility: opencode 1.15.10+
version: 0.4.1
---

# eval-harness

Behavior-regression detector for opencode skills. Bash-first, 4-class attribution, structured-output skills only.

## Triggers

Fire this skill on any of these user phrases:
- `run evals`, `run evals for <skill>`
- `check if this regressed`, `check regression`
- `baseline this skill`, `baseline <skill>`
- `did <skill> regress?`, `is my skill still working?`
- `A/B these two skills`
- `accept new behavior as baseline`

Also fires automatically via:
- `git pre-push` hook (when commits touch `.opencode/skills/**`)
- `sync-skill-to-manager` pre-publish hook (if skill opted in via `skill.yaml: evals.required: true`)

## What it does (v0.2.0)

Given a baselined skill, eval-harness:
1. Runs each case in a fully-sandboxed ephemeral environment (fresh `HOME`, `OPENCODE_CONFIG_DIR`, `NANO_BRAIN_ROOT`, cwd).
2. Runs **all** checks per case (no first-fail-exit) and aggregates failures.
3. On FAIL: classifies into `SKILL_CHANGED` / `FIXTURE_STALE` / `MODEL_CHANGED` / `UNKNOWN_DRIFT` via env-manifest diff.
4. Emits 6-field FAIL diagnostics: `failed_check_id`, `expected`, `actual`, `diff_hint`, `transcript_span`, `env_delta`.
5. Provides one-command rerun: `bash run.sh --case=X --skill=Y --debug --pin-env=baseline`.
6. Writes to `~/.config/opencode/eval-harness/runs/<id>/{results.json, diff.md, env-manifest.json, transcript.jsonl}`.
7. Appends a run event to `history.ndjson` for `eval-harness trend`.

## Commands

```bash
# Run all cases for a skill
eval-harness run --skill=omo-session-distiller

# Run one case
eval-harness run --skill=omo-session-distiller --case=atom-shape-basic

# Establish/refresh baseline (writes baselines/<case>.baseline.json)
eval-harness baseline --skill=omo-session-distiller

# Accept current behavior as new baseline (fixture only)
eval-harness accept --skill=omo-session-distiller --case=atom-shape-basic

# Also bless current env-manifest (requires confirmation; allows silent model upgrades)
eval-harness accept --skill=omo-session-distiller --case=atom-shape-basic --bless-env

# Inspect latest result
eval-harness status --latest

# Trend over last 20 runs
eval-harness trend --last=20

# Promote from WARN-ONLY (default) to BLOCKING (exit 12 actually blocks)
eval-harness promote   # requires 7-day green history + 0 bypass events
```

## Exit codes

| Code | Meaning |
|---|---|
| 0  | All cases pass (or warn-only mode hides regression) |
| 12 | Regression detected AND harness promoted to blocking |
| 13 | Harness/scorer error (NOT a skill regression) |

## Scope (read before relying on it)

**v0.1.0 is for structured-output skills only.** Cases score via:
- `shell` (deterministic command + expected output)
- `jq_path_contains` (JSON path contains required values)
- `file_exists`
- `output_contains` / `output_not_contains` (literal grep in transcript)

**Prose-output skills cannot be evaluated reliably in v0.1.0.** Deferred to v0.3 (LLM judge with cross-model debias + 3-sample majority).

## Warn-only mode (default)

After installation, eval-harness ships in WARN-ONLY mode for 7 days:
- regressions still detected, diff.md still generated, history.ndjson still appended
- exit code is 0 (push proceeds)
- promote via `eval-harness promote` once you've run 7 green days

This protects against ecosystem-wide block-rage on day 1 when cases are still being tuned.

## Bypass

```bash
EVAL_BYPASS=1 git push origin main
# → logged to history.ndjson with timestamp + skill + trigger
# → push proceeds regardless of eval state
```

## Limitations

1. Structured-output skills only (v0.3 adds LLM judge for prose).
2. Deterministic mode only (T=0, k=1); `pass@k` stochastic mode deferred to v0.2.
3. opencode 1.15.10 lacks `--max-turns` / `--skills` / `--prompt-file` flags. Compensated via `timeout(1)` + ephemeral `OPENCODE_CONFIG_DIR`.
4. Real network calls disabled by default. `--realenv` flag for opt-in quarantined cases.
5. Single-tier (no smoke/full); 2-tier deferred to v0.2 when LLM judge enters.
6. opencode Stop hook ships as a SCAFFOLD in v0.2.0 — active only on opencode ≥ 1.16 plugin API. Until then, see `scripts/eval/hooks/HOOKS.md` for manual invocation.

## See also

- Standards: [`standards/skill-quality-v1.md`](../../standards/skill-quality-v1.md) — separate skill-design review rubric (the `skill-reviewer` SKILL will consume this)
- Demo: `npm test` runs `scripts/eval/tests/regression_inject.sh` end-to-end
- Source: https://github.com/nano-step/eval-harness
