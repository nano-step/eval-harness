# @nano-step/eval-harness

[![npm](https://img.shields.io/npm/v/@nano-step/eval-harness?color=blue&label=npm)](https://www.npmjs.com/package/@nano-step/eval-harness)
[![license](https://img.shields.io/github/license/nano-step/eval-harness?color=brightgreen)](./LICENSE)
[![tests](https://img.shields.io/badge/tests-20%2F20%20green-brightgreen)](#verified-test-suites-2020-green-on-main)
[![stars](https://img.shields.io/github/stars/nano-step/eval-harness?style=social)](https://github.com/nano-step/eval-harness/stargazers)
[![discussions](https://img.shields.io/github/discussions/nano-step/eval-harness?color=blueviolet)](https://github.com/nano-step/eval-harness/discussions)
[![issues](https://img.shields.io/github/issues/nano-step/eval-harness?color=informational)](https://github.com/nano-step/eval-harness/issues)
[![good first issues](https://img.shields.io/github/issues/nano-step/eval-harness/good%20first%20issue?color=success)](https://github.com/nano-step/eval-harness/issues?q=is%3Aopen+is%3Aissue+label%3A%22good+first+issue%22)

> **Behavior-regression testing for LLM agents.** 4-class attribution, 6-field FAIL schema, $-cost gating, flaky detection. Bash + jq. Works with [opencode](https://github.com/sst/opencode) today, runner-pluggable.

<p align="center">
  <img src="./docs/assets/demo.gif" alt="eval-harness detecting a regression on git push, attributing it to SKILL_CHANGED, and rendering the 6-field FAIL with a fix_proposal." width="900">
</p>

> _The GIF above is built from [`docs/assets/demo.tape`](./docs/assets/demo.tape) with [Charm vhs](https://github.com/charmbracelet/vhs). If it's missing, run `vhs docs/assets/demo.tape`._

### Learn more

- [**Concepts**](./docs/concepts.md) — the 4 ideas that distinguish eval-harness (6-field FAIL, 4-class attribution, 3-sample stability, $-cost gating).
- [**Comparison**](./docs/comparison.md) — eval-harness vs promptfoo, DeepEval, Ragas, OpenAI Evals.
- [**Why not promptfoo?**](./docs/why-not-promptfoo.md) — direct head-to-head, when to use both.
- [**Runners**](./docs/runners.md) — runner abstraction + path to LangGraph / Claude Agent SDK / your own framework.

**v0.4.2** — Behavior-regression eval harness for [opencode](https://github.com/sst/opencode) skills.
> v0.4.2 closes all 8 BLOCKERs surfaced by independent audits: `EVAL_BYPASS` works, `score_shell` is sandboxed, fixture path-traversal blocked, `attribute.sh` portable across grep flavors, `fix_proposal` renders in `diff.md`, `--mode=2tier` aggregates verdicts correctly, empty/timed-out transcripts surface as harness errors rather than vacuous PASS.

> **Scope statement.** eval-harness measures **behavior regression** for LLM agents. Today it ships with one runner (opencode skills) and covers structured-output skills (5 deterministic check kinds) AND prose-output skills (1 LLM-judge check kind, optional). It is NOT a skill design reviewer, NOT a quality grader, NOT a general-purpose evaluator. Skill design review (frontmatter shape, trigger collisions, OWASP greps, bundle size) is a separate concern, deferred to a future `skill-reviewer` tool. Other runners (LangGraph, Claude Agent SDK) are on the v0.8.0+ roadmap — see [`docs/runners.md`](./docs/runners.md).

## What it does

Given a baselined opencode skill, eval-harness detects when behavior has regressed since the baseline, attributes the cause, and tells you exactly what changed.

```
$ git push origin main
[eval-harness] pre-push: detected change in .opencode/skills/omo-session-distiller/**
[eval-harness] running 3 cases (skills-only scope, smoke tier)
[eval-harness] Case 1/3 atom-shape-basic                       PASS (3.9s, $0.0012)
[eval-harness] Case 2/3 atom-tags-decision-architecture        FAIL
[eval-harness] Case 3/3 atom-redaction-pii                     PASS (3.1s, $0.0009)
[eval-harness] Stability check: 3 samples byte-identical → real FAIL
[eval-harness] FAIL 1/3 — see runs/2026-05-30T11-42-08/diff.md
[eval-harness] fix_proposal: missing tag "architecture" in $.atoms[].tags[]
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
# → exit 12 if regression detected (only when promoted)
```

For prose-output skills (requires `ANTHROPIC_API_KEY`):

```bash
eval-harness run --skill pr-code-reviewer --mode=full   # uses LLM judge with 3-sample majority
eval-harness run --skill pr-code-reviewer --mode=2tier  # cheap smoke first, escalate to full on FAIL
```

## Architecture

```
scripts/eval/
├── run.sh                    # entrypoint: --skill --case --mode --trigger --stability-samples --debug
├── twotier.sh                # smoke → full escalation orchestrator
├── baseline.sh               # writes baseline.json (explicit command)
├── accept.sh                 # accept --case [--bless-env]
├── status.sh                 # pull-only result inspection
├── promote.sh                # warn-only → blocking promotion
├── trend.sh                  # reads history.ndjson
├── lib/
│   ├── yq-shim.sh + _yq.py   # python-backed yq fallback (no yq binary required)
│   ├── skills_root.sh        # OPENCODE_SKILLS_ROOT resolution (env > walk-up > user-global)
│   ├── config.sh             # project-config layer (.opencode/eval-harness.yaml)
│   ├── registry.sh           # per-repo opt-in + `enable-workspace` bulk-register
│   ├── preflight.sh          # opencode binary + API key probe (fail-fast)
│   ├── lock.sh               # flock(1) coordinator (mkdir fallback for macOS)
│   ├── spawn.sh              # invokes `opencode run` with sandboxed env
│   ├── manifest.sh           # env-manifest capture (sha + model + version + platform)
│   ├── score.sh              # runs all 6 check kinds against transcript + fs
│   ├── llm_judge.sh          # Anthropic API call, 3-sample majority voting
│   ├── autofix.sh            # heuristic fix_proposal enrichment
│   ├── pricing.sh            # token → dollar conversion + staleness gate
│   ├── stability.sh          # 3-sample byte-identical check on FAIL
│   ├── diff.sh               # 6-field FAIL output + per-case cost + stability
│   └── attribute.sh          # 4-class attribution decision tree
├── hooks/
│   ├── pre-push              # git hook installer target
│   ├── sync-publish.sh       # sync-skill-to-manager pre-publish hook
│   ├── opencode-stop.sh      # scaffold (gated on opencode ≥ 1.16 plugin API)
│   └── HOOKS.md              # hook reference
└── tests/                    # 11 test suites — see "Verify" section
```

## Design highlights

- **Bash + jq + flock**. No daemon, no Node CLI, no Unix socket. Python only as a `yq` fallback.
- **3 active triggers + 1 scaffold**: `sync-skill-to-manager` pre-publish · git `pre-push` on skill edits · manual `eval-harness run` · opencode Stop hook (scaffolded; activates on opencode ≥ 1.16).
- **6-field FAIL schema**: `failed_check_id`, `expected`, `actual`, `diff_hint`, `transcript_span`, `env_delta`.
- **4-class attribution**: `SKILL_CHANGED`, `FIXTURE_STALE`, `MODEL_CHANGED`, `UNKNOWN_DRIFT`. Tagged `flaky:true` when 3-sample stability check finds samples diverged.
- **2-tier execution mode**: `--mode=smoke` (cheap haiku, 1 LLM-judge sample) by default. `--mode=full` (configured model, 3 samples). `--mode=2tier` runs smoke, re-runs only failed cases with full.
- **Dollar cost per case**: `pricing.json` curated rates for haiku-3-5, sonnet-4-6, opus-4-7. `summary.total_cost_usd` per run. Staleness gate (default 60 days).
- **Per-(case,trigger) lockfile**: `flock(1)` serializes concurrent invocations on the same skill+case+trigger.
- **Per-repo opt-in registry** + **bulk register**: required for multi-repo workspaces. Manual trigger always runs; automated triggers (pre-push / sync-publish / stop-hook) skip non-enabled repos. One command opts every skill-bearing repo in: `registry.sh enable-workspace --root=<path>`.
- **Project-config layer**: `.opencode/eval-harness.yaml` walked up from cwd. Env vars win when explicitly set.
- **Per-case model override**: case YAML `.model` field. Resolution: case > env > project config > built-in.
- **3-sample byte-identical stability check** on FAIL → flaky tag if mismatch, no false attribution.
- **Warn-only by default**. Promote with `eval-harness promote` (manual). Auto-promotion after N green days is a v0.6.0 item, not shipped yet.
- **Two-stage `accept`**: default updates fixtures only; `--bless-env` required to update env-manifest (with confirmation).
- **Heuristic auto-fix proposals**: every FAILED check on a safe kind carries a `.fix_proposal` with `instruction` + `patch_snippet`. Rendered in `diff.md`. Never auto-applies — proposes only (applier is v0.5.0).
- **Cost ceiling**: `EVAL_BUDGET_USD=2.00` hard daily cap. Tokens-based capture.
- **One-command rerun** in every FAIL output.

---

## What this harness scores (the factors)

Be explicit about what is and isn't checked. eval-harness evaluates **two layers** with different jobs:

### Layer 1 — Behavior factors (eval-harness itself, this repo, this version)

Every case in `.opencode/skills/<skill>/evals/cases/*.yaml` declares one or more **checks**. The harness runs **all checks** per case and aggregates failures. **6 check kinds** are supported today:

| # | Check kind | What it scores | Reliability |
|---|---|---|---|
| 1 | `shell`               | Runs a shell command in the case workdir; matches stdout against `expect_regex` / `expect_min` / `expect_exact`. | High — deterministic. |
| 2 | `jq_path_contains`    | Reads a JSON file in workdir, walks a jq path, asserts the result array contains all `contains:` values. | High — deterministic. |
| 3 | `file_exists`         | Asserts a file exists at the given path in workdir. | High — deterministic. |
| 4 | `output_contains`     | Greps the opencode transcript for a literal string. Records `transcript_span` on hit. | High — deterministic, literal-only. |
| 5 | `output_not_contains` | Inverse of #4. Used for refusal / forbidden-output checks. | High — deterministic, literal-only. |
| 6 | `llm_judge`           | Calls Anthropic Messages API (default `claude-sonnet-4-6`, configurable to `claude-opus-4-7`) with a rubric. 3-sample majority voting. **Returns `verdict: null` honestly** when API key missing, response unparseable, or majority null — never fabricates a verdict. | Medium — model-judged, with explicit failure modes. |

If your case YAML uses an unrecognised `kind:`, the harness emits an `error: true` result and excludes it from regression diff — it does not silently pass.

### Layer 2 — Environment & attribution factors (for FAIL diagnosis)

When a case fails, the harness attributes the cause using environment-manifest fields captured per run:

| Manifest field | Catches |
|---|---|
| `skill_bundle_sha` (transitive hash of all skills) | `SKILL_CHANGED` |
| `skill_sha` (just this skill) | `SKILL_CHANGED` (narrower) |
| `fixture_sha` (case fixture directory) | `FIXTURE_STALE` |
| `model_id` + `opencode_version` | `MODEL_CHANGED` |
| (none of the above changed) | `UNKNOWN_DRIFT` |
| 3-sample stability divergence | `flaky: true` tag on attribution |

`MCP_FLAKE` and `HARNESS_BUG` are designed but not shipped (deferred until they bite).

### Layer 3 — Skill *design* factors (NOT in this repo)

A separate concern, deferred to a future `skill-reviewer` tool. eval-harness does **not** review skill design quality (trigger phrase collisions, frontmatter shape, examples present, security greps, bundle size, etc.).

A draft heuristic for design review lives at [`standards/skill-quality-v1.md`](./standards/skill-quality-v1.md). Read it understanding that:

- **13 of 30 factors** are grounded in real sources (Anthropic Skills doc + OWASP shell-security greps + MCP tool conventions). Reliable to apply.
- **17 of 30 factors** are heuristic synthesis from pattern-matching across one workspace. Use with judgment; treat as "things to consider," not "things that pass/fail."
- There is **no published, authoritative skill-quality benchmark** in the industry today. Anyone claiming one is synthesising — same as we are. This doc is honest about which factors are grounded vs invented.

---

## The review workflow — how factors get enforced

There are **two active workflows + one scaffold**. Each enforces a specific subset of factors at a specific gate.

### Workflow A — Behavior regression (automatic, every push)

```mermaid
flowchart TD
  A[Skill edited in .opencode/skills/X/] --> B{git push?}
  B -- yes --> C[pre-push hook fires]
  C --> D{Repo enabled in registry?}
  D -- no  --> Z[skip, push proceeds]
  D -- yes --> E[Detect affected skill from changed files]
  E --> F[Acquire flock on skill:case:trigger]
  F --> G[Sandbox each case: ephemeral HOME/OPENCODE_CONFIG_DIR/cwd]
  G --> H[Spawn opencode run with skills_loaded pinned]
  H --> I[Run ALL 6-kind checks per case]
  I --> J{Any case FAIL?}
  J -- no --> K[exit 0, push proceeds]
  J -- yes --> L[3-sample stability check]
  L --> M[Compute env_delta + 4-class attribution + fix_proposal]
  M --> N[Render diff.md with 6-field FAIL detail + cost]
  N --> O{Promoted to BLOCKING?}
  O -- no  --> P[Warn-only: exit 0, push proceeds]
  O -- yes --> Q[exit 12, push BLOCKED unless EVAL_BYPASS=1]
```

**Factors enforced**: Layer 1 (6 check kinds) + Layer 2 (4 attribution fields + flaky tag). Plus dollar-cost accounting + auto-fix proposals.

### Workflow B — Pre-publish (opt-in, before npm publish)

```mermaid
flowchart TD
  A[sync-skill-to-manager publish X] --> B[Read skill.yaml]
  B --> C{evals.required: true?}
  C -- no --> D[Skip eval gate, publish proceeds]
  C -- yes --> E{X is eval-harness itself?}
  E -- yes --> F[Whitelisted, publish proceeds]
  E -- no  --> G{Repo enabled in registry?}
  G -- no  --> Y[skip, publish proceeds]
  G -- yes --> H[Run full eval suite for X]
  H --> I{Any regression vs baseline?}
  I -- no --> J[exit 0, publish proceeds]
  I -- yes --> K[exit 12, publish BLOCKED]
```

### Workflow C — opencode Stop hook (scaffold)

Scaffolded in v0.2.0, **inactive** until opencode ≥ 1.16 plugin API ships. The hook parses `OPENCODE_CHANGED_FILES` and re-runs evals for any touched skill. Until upstream lands the plugin API, the script is a no-op (exit 0 with a one-line skip message). See [`scripts/eval/hooks/HOOKS.md`](./scripts/eval/hooks/HOOKS.md) for manual invocation.

### What each workflow does NOT enforce

| Concern | Workflow A (push) | Workflow B (publish) | Status |
|---|---|---|---|
| Trigger phrase collision with other skills | ❌ | ❌ | Future `skill-reviewer` tool |
| Frontmatter schema validation | ❌ | ❌ | Future `skill-reviewer` tool |
| OWASP shell-security greps | ❌ | ❌ | Future `skill-reviewer` tool |
| Bundle size / context cost | ❌ | ❌ | Future `skill-reviewer` tool |
| Prose output quality | ✅ via `llm_judge` | ✅ via `llm_judge` | Shipped v0.3.0 (requires `ANTHROPIC_API_KEY`) |
| Cross-skill behavioral interaction | ⚠️ partial (via `skill_bundle_sha`) | ⚠️ partial | Tracked but not gated |
| Cost regression (tokens/dollars rising) | ⚠️ captured per-case, not gated | ⚠️ captured | Shipped v0.2.0 (visibility only; gating is v0.5.0+) |
| Stop-hook on idle | 🚧 scaffold | n/a | Activates on opencode ≥ 1.16 |

This table is the **honest scope statement**. Anything not in Workflow A/B (or actively scaffolded in C) is not enforced.

---

## How to verify the harness is actually running these factors

Four reproducible commands, each scoped to a different layer:

```bash
# Layer 1 + Layer 2 — full pipeline including attribution
npm test
# → runs scripts/eval/tests/regression_inject.sh
# → asserts: verdict=REGRESSION, attribution=SKILL_CHANGED, 6-field FAIL populated
# → exit 0 = harness is real

# Layer 1 — dry-run case discovery only (no API spend; preflight still runs)
EVAL_SKIP_AUTH_CHECK=1 eval-harness run --skill=<your-skill> --dry-run

# Layer 1 — single check kind in isolation
bash scripts/eval/lib/score.sh check <one-check.yaml> <workdir> <transcript>

# Full test suite — 21 suites covering every primitive
for t in scripts/eval/tests/*.sh; do bash "$t"; done
# → all should print PASS
```

If you need to know whether a specific factor is being checked, point at the case YAML — `.checks[]` is the complete list of factors that case enforces. There is no hidden scoring.

### Verified test suites (21/21 green on `main`)

| Suite | Covers |
|---|---|
| `regression_inject.sh`        | End-to-end demo: inject regression, assert SKILL_CHANGED + 6-field FAIL |
| `case_model_override.sh`      | Per-case `.model` field flows into env-manifest |
| `project_config.sh`           | `.opencode/eval-harness.yaml` + env-var precedence |
| `registry.sh`                 | init / enable / disable / list / is-enabled / repo-name |
| `registry_bulk.sh`            | `enable-workspace` discover (all/skills/cases), dry-run, single-write merge, idempotency, preserves manual entries |
| `lock_concurrency.sh`         | Two parallel same-case runs serialized via flock |
| `pricing.sh`                  | Cost math + staleness states (FRESH/STALE/MISSING) + token extraction |
| `stability_inline.sh`         | 3-sample byte-identical hashing on FAIL |
| `stop_hook.sh`                | Version gate + empty changed-set handling |
| `llm_judge_unit.sh`           | PASS / FAIL / ERROR paths + 3-sample majority + missing-key fallback |
| `twotier_mode.sh`             | Smoke pins haiku, full pins sonnet-4-6, 2tier orchestrates, invalid mode rejected |
| `twotier_aggregation.sh`      | 2tier escalation aggregates verdicts across all failed cases (closes BLK-6) |
| `autofix.sh`                  | Fix proposals for safe check kinds; null for llm_judge & passing checks |
| `fix_proposal_render.sh`      | `fix_proposal` renders in `diff.md` (closes BLK-5) |
| `bypass.sh`                   | `EVAL_BYPASS=1` exits 0 + writes bypass event (closes BLK-1) |
| `shell_safety.sh`             | `score_shell` filter accepts jq/pipes/wc; rejects rm/curl/`$()`/backtick/`>`; honors `unsafe_shell:` opt-in (closes BLK-2) |
| `shell_no_expectation.sh`     | `score_shell` treats missing `expect_*` fields as harness errors, not ordinary FAILs |
| `fixture_path_traversal.sh`   | Fixture copy rejects absolute paths + `..` segments (closes BLK-3) |
| `attribution_portable.sh`     | Attribution works under GNU + BSD grep (closes BLK-4) |
| `transcript_empty_guard.sh`   | Missing/empty transcript → harness error not vacuous PASS (closes BLK-7) |
| `spawn_timeout_guard.sh`      | `timeout(1)` exit 124 → harness error not silent partial-transcript score (closes BLK-8) |

## Triggers

| Trigger | Mode | Blocks? | Cases |
|---|---|---|---|
| `sync-skill-to-manager` pre-publish | sync, no timeout | warn-only (promote to block) | full suite for skill |
| git `pre-push` | sync, 60s timeout | warn-only (promote to block) | affected fast cases |
| manual (`eval-harness run`) | sync, foreground | n/a | user-specified |
| opencode Stop hook | scaffold (inactive until opencode ≥ 1.16) | n/a | skills with changed files |

## Configuration

### `.opencode/eval-harness.yaml` (per-project, optional)

```yaml
model: anthropic/claude-3-5-haiku-latest
budget_usd: 2.00
max_seconds: 180
llm_judge:
  model: anthropic/claude-sonnet-4-6
```

Walked up from cwd. Explicit env vars (`EVAL_MODEL`, `EVAL_BUDGET_USD`, etc.) still win.

### Per-repo registry (required for multi-repo workspaces)

The registry is the opt-in gate for **automated** triggers (pre-push, sync-publish, stop-hook). Manual `eval-harness run` ignores the registry and always works.

```bash
# One repo at a time:
bash scripts/eval/lib/registry.sh enable <repo-name>
bash scripts/eval/lib/registry.sh disable <repo-name>
bash scripts/eval/lib/registry.sh list

# Bulk: opt every skill-bearing repo under a root in one call.
# (Filters out repos that have no .opencode/skills/ — registering them is noise.)
bash scripts/eval/lib/registry.sh enable-workspace --root=/path/to/workspace

# Preview without writing:
bash scripts/eval/lib/registry.sh enable-workspace --root=/path/to/workspace --dry-run

# Tighter filter — only repos that already have evals/cases/*.yaml:
bash scripts/eval/lib/registry.sh enable-workspace --root=/path --filter=cases

# Loosest filter — every .git repo under root, even ones with no skills:
bash scripts/eval/lib/registry.sh enable-workspace --root=/path --filter=all
```

Filter values: `skills` (default — repos with `.opencode/skills/<X>/`), `cases` (repos with eval cases written), `all` (every git repo).

Bulk-register is **idempotent**: re-running with the same args adds zero new entries. It **preserves** any repos enabled manually beforehand (set union, not replace).

Default registry path: `~/.config/opencode/eval-harness/registry.yaml`. Override with `$EVAL_HARNESS_REGISTRY`.

### Wiring the pre-push hook everywhere

Git hooks live inside each repo's `.git/hooks/`. To get the eval-harness pre-push hook on **every** repo on the machine without per-repo install, use git's `core.hooksPath`:

```bash
# 1. Make a global hooks directory
mkdir -p ~/.config/git/hooks

# 2. Drop the eval-harness pre-push hook in
cp $(npm root -g)/@nano-step/eval-harness/scripts/eval/hooks/pre-push ~/.config/git/hooks/
chmod +x ~/.config/git/hooks/pre-push

# 3. Tell git to use it globally
git config --global core.hooksPath ~/.config/git/hooks
```

Now every `git push` on this machine fires the hook. The hook only invokes `eval-harness` when the push touches `.opencode/skills/<X>/` files **and** the repo is opted in via the registry. All other pushes return immediately with no overhead.

Per-repo install (alternative) for a single repo:

```bash
cd /path/to/your/repo
bash $(npm root -g)/@nano-step/eval-harness/scripts/eval/install-hooks.sh
```

### Pricing data

[`pricing.json`](./pricing.json) carries curated input/output per-Mtok USD rates for haiku-3-5, sonnet-4-6, opus-4-7. Update the `as_of` date and rates when Anthropic prices change; the staleness gate warns after 60 days (configurable via `stale_after_days` in the file, or `EVAL_FAIL_ON_STALE_PRICING=1` to refuse runs).

## Limitations (read before using)

1. **opencode 1.15.10 verified.** opencode ≥ 1.16 needed to activate the Stop hook; earlier versions: file an issue.
2. **No `--max-turns` / `--skills` flags exist in opencode** → enforced via filesystem (ephemeral `OPENCODE_CONFIG_DIR` + external `timeout(1)` + token-counted kill).
3. **No real network calls** in default mode. `--realenv` flag for opt-in quarantined cases.
4. **LLM judge requires `ANTHROPIC_API_KEY`.** Without one, `llm_judge` checks return `verdict: null` with `reason: judge_unavailable` — this is by design (we never fabricate a verdict). Set the key to use prose-output evaluation.
5. **Deterministic mode only** (T=0, k=1). Stochastic `pass@k` deferred to v0.7.0.
6. **Auto-fix proposes, never applies.** Each FAILED check carries a `fix_proposal` (visible in `diff.md`) but `auto_apply: false`. An `eval-harness apply` command is tracked in v0.5.0.
7. **Cost is captured, not gated.** Per-case + per-run dollar amounts surface in `results.json` and `diff.md`, but only `EVAL_BUDGET_USD` (daily token cap, per-process) hard-stops execution. Shared-state budget ledger + cost-regression gating are tracked in v0.5.0.
8. **No `--strict` mode yet.** Warn-only is the only mode in v0.4.x. CI-grade gating requires `eval-harness promote` (manual) or waiting for v0.5.0's `--strict` flag (issue #10).

## Authoring a case (5 min)

Structured-output case (deterministic, no API cost beyond the spawn):

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

Prose-output case (uses `llm_judge`, needs `ANTHROPIC_API_KEY`):

```yaml
schema_version: 2
id: review-must-flag-sql-injection
mode: prose
skill_under_test: pr-code-reviewer
skills_loaded: [pr-code-reviewer]
model: anthropic/claude-sonnet-4-6   # optional per-case override

setup:
  fixtures:
    "diff.patch": ./fixtures/pr-sql-injection.diff

prompt: "Review the diff in diff.patch. Write your review to review.md."

checks:
  - kind: file_exists
    path: review.md
  - kind: llm_judge
    target_file: review.md
    samples: 3
    judge_model: anthropic/claude-sonnet-4-6   # optional; defaults to EVAL_LLM_JUDGE_MODEL
    rubric: |
      The review MUST identify the SQL injection vulnerability AND recommend
      reverting to parameterized queries. PASS only if both are present.
      FAIL if SQL injection is missed or treated as below HIGH severity.
```

Run `eval-harness run --skill=pr-code-reviewer --mode=2tier` to evaluate cheaply with auto-escalation.

## Versions

| Version | Released | Highlights |
|---|---|---|
| **v0.4.2** | 2026-05-30 | Hardening: closed all 8 audit BLOCKERs — bypass crash, score_shell RCE, fixture traversal, macOS attribution, fix_proposal rendering, 2tier aggregation, empty transcripts, timeout handling |
| v0.4.1 | 2026-05-30 | Fix npm-link symlink resolution in entrypoint scripts |
| v0.4.0 | 2026-05-29 | Heuristic auto-fix proposer for safe check kinds |
| v0.3.0 | 2026-05-29 | LLM judge (sonnet-4-6 / opus-4-7, 3-sample majority) · `pr-code-reviewer` demo · 2-tier mode |
| v0.2.0 | 2026-05-29 | Project config · per-case model override · per-repo registry · flock lockfile · pricing/cost · stability on critical path · Stop-hook scaffold |
| v0.1.1 | 2026-05-29 | Patch: model ID + demo path + factors README + SQS-1 honesty |
| v0.1.0 | 2026-05-28 | Initial release: bash + pre-push + sync-publish + 4-class attribution + omo-session-distiller demo |

Unreleased post-v0.4.2 work on `main`:
- `registry.sh enable-workspace` — bulk-register all skill-bearing repos under a workspace root (will ship as part of v0.4.3)

See [`CHANGELOG.md`](./CHANGELOG.md) for details.

## Roadmap

v0.4.2 (2026-05-30) closed all 8 BLOCKERs surfaced by independent audits. v0.4.3 work has started — bulk workspace registration shipped, 9 polish items remain.

See [`KNOWN_ISSUES.md`](./KNOWN_ISSUES.md) for the remaining HIGH/MEDIUM items, [`CONTRIBUTING.md`](./CONTRIBUTING.md) for how to land a PR, and the [📍 pinned roadmap issue #26](https://github.com/nano-step/eval-harness/issues/26) for the latest priorities.

**Want to help?** 26 issues are open with clear scope. [Browse `good first issue`](https://github.com/nano-step/eval-harness/issues?q=is%3Aopen+label%3A%22good+first+issue%22) (small, well-scoped) or [`help wanted`](https://github.com/nano-step/eval-harness/issues?q=is%3Aopen+label%3A%22help+wanted%22) (larger features needing design discussion).

### v0.4.2 — Hardening release ✅ shipped 2026-05-30

All 8 BLOCKERs closed:
- ✅ Fixed `EVAL_BYPASS=1` crash (function-before-definition)
- ✅ Sandboxed `score_shell`'s `bash -c "$cmd"` with metachar/dangerous-binary filter
- ✅ Fixed fixture-copy subshell + path-traversal guard (absolute paths + `..` blocked)
- ✅ Fixed `attribute.sh` BRE alternation (works on macOS BSD grep now)
- ✅ Rendered `.fix_proposal` in `diff.md` (auto-fix feature finally visible)
- ✅ Fixed `--mode=2tier` verdict aggregation across escalated cases
- ✅ Treat empty/missing transcript as harness error, not vacuous PASS
- ✅ Handle `timeout(1)` exit 124 as harness error

### v0.4.3 — Correctness polish (in progress)

- ✅ **`registry.sh enable-workspace`** — bulk-register all skill-bearing repos under a workspace root (shipped post-v0.4.2)
- `trap` for lock fd / mkdir-lock cleanup on SIGINT/SIGTERM (issue #1)
- Larger run-ID collision space — `$RANDOM$RANDOM` or `openssl rand` (#2)
- Preflight `python3` + `pyyaml` presence (#3)
- LLM-judge verdict parser: scan only first line of response (#4)
- `flock` the `history.ndjson` append (#5)
- Cap `samples:` field in case YAML — prevent runaway cost (#6)
- Delete dead-code `propose_fixes_for_run` tautology bug (#7)
- Detect 'no expectation' misconfig in shell check (#8)
- Remove `$workdir` PATH-prepend in spawn.sh (#9)
- macOS CI matrix (#24)

### v0.5.0 — CI-ready

The first version safe to recommend for CI/CD gating.

- `--strict` mode — flip warn-only off; exit 12 on first regression (#10)
- `--ci` mode + JUnit / SARIF reporter + PR-comment integration (#11)
- Shared-state daily budget ledger — `EVAL_BUDGET_USD` actually enforced across runs (#12)
- Self-eat suite: `skills/eval-harness/evals/cases/*.yaml` for the harness itself (#13)
- Auto-fix **applier** — `eval-harness apply --run=<id>` (#14)
- Cost-regression gating — block PRs that raise per-case $ vs baseline
- Semver + deprecation policy documented (#22)
- GitHub Actions example workflow (#23)
- End-to-end demo script (#25)

### v0.6.0 — DX polish

- Pre-push branch filter — skip WIP/draft branches (#15)
- Cross-skill behavioral interaction diagnosis (#16)
- Automatic warn-only → blocking promotion after N green days (#17)
- A/B mode — `eval-harness ab --base=X --candidate=Y` (#18)
- opencode Stop-hook activation once plugin API lands

### v0.7.0 — Scale

- Anthropic API rate-limit handling + exponential backoff (#19)
- Judge response caching by `(rubric_hash + artifact_hash)` (#20)
- Stochastic `pass@k` mode — T>0, multiple samples per case (#21)
- Per-run cost cap (`EVAL_BUDGET_USD` currently daily-only)
- `MCP_FLAKE` + `HARNESS_BUG` attribution classes

### v1.0.0 — Stable

Trigger criteria (all must be true):

- ✅ All BLOCKERs from 2026-05-30 audits closed (done in v0.4.2)
- All HIGH severity items closed (target: v0.4.3)
- Self-eaten on own evals (#13 → v0.5.0)
- Semver + deprecation policy published (#22 → v0.5.0)
- CI-proven on ≥1 external repo (community signal)
- 30 days of stable releases with no critical bug reports

### Out of scope (separate project)

**`skill-reviewer`** — Layer-3 design review (frontmatter schema, trigger-phrase collisions, OWASP shell greps, bundle size, examples-present, deprecation references). Different tool, different repo, different release cadence. See [`standards/skill-quality-v1.md`](./standards/skill-quality-v1.md) for the draft rubric.

---

> *Forged in the regression furnace.*
> MIT · Hoài Nhớ · [nano-step](https://github.com/nano-step)
