# @nano-step/eval-harness

**v0.1.0** — Behavior-regression eval harness for [opencode](https://github.com/sst/opencode) skills.

> Scope statement: v0.1.0 measures **behavior regression** for **structured-output skills**. It is NOT a skill reviewer, NOT a quality grader, NOT a general-purpose evaluator. Prose-output skills (`pr-code-reviewer`, `od-workflow`, …) are deferred to v0.3 (LLM judge).

## What it does

Given a baselined opencode skill, eval-harness detects when behavior has regressed since the baseline, attributes the cause, and tells you exactly what changed.

```
$ git push origin main
[eval-harness] pre-push: detected change in .opencode/skills/omo-session-distiller/**
[eval-harness] running 3 cases (skills-only scope, fast tier)
[eval-harness] Case 1/3 atom-shape-basic                       PASS (3.9s)
[eval-harness] Case 2/3 atom-tags-decision-architecture        FAIL
[eval-harness] Case 3/3 atom-redaction-pii                     PASS (3.1s)
[eval-harness] Stability check: 3 samples byte-identical → real FAIL
[eval-harness] FAIL 1/3 — see runs/2026-05-28T11-42-08/diff.md
[eval-harness] WARN-ONLY MODE: push proceeding. Promote with `eval-harness promote`.
```

## Install

```bash
npm install -g @nano-step/eval-harness
```

Or use directly from a clone:

```bash
git clone https://github.com/nano-step/eval-harness.git
export PATH="$PWD/eval-harness/scripts/eval:$PATH"
```

## Quick start (5 min)

```bash
# 1. Run the canonical demo (mutates omo-session-distiller, runs eval, reverts)
npm test

# 2. Use it on a real skill — first baseline
eval-harness baseline --skill omo-session-distiller

# 3. Edit the skill, then run again
eval-harness run --skill omo-session-distiller
# → exit 12 if regression detected
```

## Architecture (v0.1.0)

```
scripts/eval/
├── run.sh                    # entrypoint: --case --skill --debug --full --pin-env
├── baseline.sh               # writes baseline.json (explicit command)
├── accept.sh                 # accept --case [--bless-env]
├── status.sh                 # pull-only result inspection
├── promote.sh                # warn-only → blocking promotion
├── trend.sh                  # reads history.ndjson
├── lib/
│   ├── spawn.sh              # invokes `opencode run` with sandboxed env
│   ├── score.sh              # runs all checks against transcript + fs
│   ├── diff.sh               # 6-field FAIL output computation
│   ├── attribute.sh          # 4-class attribution decision tree
│   ├── manifest.sh           # env-manifest capture
│   └── stability.sh          # 3-sample byte-identical check on FAIL
├── hooks/
│   ├── pre-push              # git hook installer target
│   └── sync-publish.sh       # sync-skill-to-manager pre-publish hook
└── tests/regression_inject.sh   # the canonical demo
```

## v0.1.0 design highlights

- **Bash + jq + flock**. No daemon, no Node CLI, no Unix socket.
- **3 auto-triggers**: `sync-skill-to-manager` pre-publish · git `pre-push` on skill edits · manual `eval-harness run`. (Stop hook deferred — opencode plugin API unverified.)
- **6-field FAIL schema**: `failed_check_id`, `expected`, `actual`, `diff_hint`, `transcript_span`, `env_delta`.
- **4-class attribution**: `SKILL_CHANGED`, `FIXTURE_STALE`, `MODEL_CHANGED`, `UNKNOWN_DRIFT`.
- **3-sample byte-identical stability check** on FAIL → flaky tag if mismatch, no false attribution.
- **Warn-only by default** for 7 days. Promote with `eval-harness promote`.
- **Two-stage `accept`**: default updates fixtures only; `--bless-env` required to update env-manifest (with confirmation).
- **Cost ceiling**: `EVAL_BUDGET_USD=2.00` hard daily cap. Tokens-based capture.
- **One-command rerun** in every FAIL output.

## Triggers

| Trigger | Mode | Blocks? | Cases |
|---|---|---|---|
| `sync-skill-to-manager` pre-publish | sync, no timeout | warn-only (promote to block) | full suite for skill |
| git `pre-push` | sync, 60s timeout | warn-only (promote to block) | affected fast cases |
| manual (`eval-harness run`) | sync, foreground | n/a | user-specified |

## Limitations (read before using)

1. **Structured-output skills only.** Prose-output skills cannot be evaluated. v0.3 will add LLM judge.
2. **Deterministic mode only** (T=0, k=1). Stochastic / `pass@k` deferred to v0.2.
3. **opencode 1.15.10 verified.** Earlier/later versions: file an issue.
4. **No `--max-turns` / `--skills` flags exist in opencode** → enforced via filesystem (ephemeral `OPENCODE_CONFIG_DIR` + external `timeout(1)` + token-counted kill).
5. **No real network calls** in default mode. `--realenv` flag for opt-in quarantined cases.

## Authoring a case (5 min)

```yaml
schema_version: 2
id: smoke-001-my-case
mode: deterministic
skill_under_test: omo-session-distiller
skills_loaded: [omo-session-distiller]
description: "Skill must produce atoms with required keys"

setup:
  fixtures:
    "session.json": ./fixtures/session-input.json

prompt: "Distill the session at session.json. Write JSON atoms to atoms.json."

budget:
  max_tokens: 50000
  max_seconds: 180

checks:
  - kind: shell
    cmd: "jq -r '.atoms | length' atoms.json"
    expect_min: 1
  - kind: jq_path_contains
    file: atoms.json
    path: "$.atoms[0].tags"
    contains: ["decision", "architecture"]
```

## Roadmap

- **v0.1.0** ← current: bash + pre-push + sync-publish + 4-class attribution + omo-session-distiller demo
- **v0.2.0**: opencode Stop hook (after plugin API verified) + per-repo opt-in registry
- **v0.3.0**: LLM judge (claude-haiku, cross-model debias, 3-sample majority) for prose-output skills + `pr-code-reviewer` demo
- **v0.4.0**: heuristic auto-fix proposer (constrained to literal/regex checks)

## License

MIT © Hoài Nhớ ([nano-step](https://github.com/nano-step))
