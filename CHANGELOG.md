# Changelog

All notable changes to `@nano-step/eval-harness` are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
this project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- `preflight_check` now reports missing `python3` or PyYAML when the `yq` binary is absent and the yq-shim fallback would otherwise fail later without a useful hint.

## [0.4.2] — 2026-05-30

### Fixed (8 BLOCKERs surfaced by 2026-05-30 audits)

- **BLK-1**: `EVAL_BYPASS=1` no longer crashes. Bypass logic moved above all dependent state and renamed the helper to `log_bypass_event` to avoid the function-before-definition trap. `run.sh:177`.
- **BLK-2**: `score_shell` now rejects YAML-supplied commands containing shell metacharacters (`$()`, backticks, `>`, `<`, `&`, `;`, `\\${...}`) and dangerous binaries (`rm`, `curl`, `wget`, `nc`, `sudo`, `dd`, `eval`, `exec`, `source`, etc.) by default. Opt in per-check with `unsafe_shell: true` or globally with `EVAL_ALLOW_UNSAFE_SHELL=1`. `score.sh:51`.
- **BLK-3**: Fixture-copy loop now uses `< <(...)` instead of `| while` (errors propagate), rejects absolute paths and `..` segments, and resolves each `dest` against the workdir with `os.path.normpath` before copying. `run.sh:249`.
- **BLK-4**: Attribution now uses `grep -qE "^(skill_bundle_sha|skill_sha)$"` (ERE) instead of `grep -qx "skill_bundle_sha\\|skill_sha"` (broken on macOS BSD grep). `SKILL_CHANGED` fires correctly across both grep flavors. `attribute.sh:18`.
- **BLK-5**: `fix_proposal` is now rendered in `diff.md` under each failed check (kind + confidence + instruction + patch_snippet). The v0.4.0 feature is finally visible to users. `diff.sh:179`.
- **BLK-6**: `--mode=2tier` now aggregates verdicts across all escalated cases into a single `2tier-<timestamp>/results.json` with `summary.{full_pass, full_fail, regression_count}` and `contributing_run_ids[]`. Exits 12 if any escalated case is a confirmed regression vs baseline, instead of returning the rc of the last loop iteration. `twotier.sh`.
- **BLK-7**: `output_not_contains` returns `passed: false, error: true` on missing or empty transcripts instead of vacuous-PASS. A skill that fails to run no longer scores PASS on negative checks. `score.sh:247`.
- **BLK-8**: `timeout(1)` exit 124 surfaces as a `harness_error` kind check with explicit diagnostic, rather than silently scoring against a partial transcript. Same handling for any non-zero spawn exit + empty transcript. `run.sh:326`.

### Added

- 8 new regression tests guarding each BLOCKER fix: `bypass.sh`, `shell_safety.sh`, `fixture_path_traversal.sh`, `attribution_portable.sh`, `fix_proposal_render.sh`, `twotier_aggregation.sh`, `transcript_empty_guard.sh`, `spawn_timeout_guard.sh`.

### Verified

- 19/19 test suites green (v0.4.1's 11 + 8 new BLOCKER-guard suites).

## [0.4.1] — 2026-05-30

### Fixed
- **Install via `npm link` / `npm install -g` was broken.** Top-level entrypoints (`run.sh`, `twotier.sh`, `accept.sh`, `baseline.sh`, `install-hooks.sh`) resolved `BASH_SOURCE[0]` via `$(dirname …)` only, which returned the symlink directory (the npm `bin/`), not the package's actual `scripts/eval/` directory. Sourcing siblings then failed with "No such file or directory". Each entrypoint now walks the symlink chain portably (BSD/Linux compatible, no `readlink -f` dependency) before resolving its own dir.

## [0.4.0] — 2026-05-29

### Added
- **Heuristic auto-fix proposer** — `scripts/eval/lib/autofix.sh` attaches `.fix_proposal` to every FAILED check whose failure mode is mechanically diagnosable: `output_contains`, `output_not_contains`, `jq_path_contains`, `file_exists`, `shell` (exact / min / regex). Each proposal carries `kind`, `confidence`, `instruction`, `patch_snippet`, and `auto_apply: false`. `llm_judge` and unknown kinds yield `fix_proposal: null` — the harness won't guess prose. Gated by `EVAL_AUTOFIX` (default 1). (PR #13)

### Verified
- 11 test suites green (v0.3.0's 10 + autofix).

## [0.3.0] — 2026-05-29

### Added
- **LLM judge** — new check kind `llm_judge` for prose-output skills. Calls Anthropic Messages API directly via `curl` with `ANTHROPIC_API_KEY`. Default `claude-sonnet-4-6`; configurable to `claude-opus-4-7` via `EVAL_LLM_JUDGE_MODEL` or per-check `judge_model`. 3-sample majority voting (`samples: N` per check). Returns `verdict: null` with explicit `reason` when API key missing, curl fails, response unparseable, or majority null — never fabricates a verdict. (PR #9)
- **pr-code-reviewer demo skill** — second skill alongside `omo-session-distiller`. 3 prose cases exercising the `llm_judge` check kind: adversarial SQL injection (must flag), false-positive control trivial rename (must approve), and partial-failure billing risk (must flag). (PR #10)
- **2-tier mode** — `--mode={smoke|full|2tier}`. `smoke` (cheap haiku + 1 sample) is default. `full` (sonnet-4-6 + 3 samples) is the canonical pass. `2tier` runs smoke first, then re-runs only the FAILED cases with full. Trigger string `2tier-escalation` for history transparency. (PR #11)

### Fixed
- **`run.sh` SCRIPT_DIR shadowing** — `lib/diff.sh` reassigned the variable on source, breaking sibling-script resolution from `run.sh`. Now uses `RUN_SCRIPT_DIR` for run.sh-owned paths.

### Verified
- 10 test suites green: all of v0.2.0's 8 + llm_judge_unit + twotier_mode.

## [0.2.0] — 2026-05-29

### Added
- **Per-case model override** — case YAML `.model` field. Resolution: case YAML > `EVAL_MODEL` > `OPENCODE_MODEL` > built-in default. Recorded in env-manifest so MODEL_CHANGED attribution fires correctly. (PR #1)
- **Project-config layer** — `.opencode/eval-harness.yaml` walked up from cwd. Settings: `model`, `budget_usd`, `max_seconds`, `skills_root`, `llm_judge.model`. Env vars win when explicitly set. (PR #2)
- **opencode Stop hook scaffold** — `scripts/eval/hooks/opencode-stop.sh` parses `OPENCODE_CHANGED_FILES` and re-runs evals for touched skills. Gated on `opencode >= 1.16` (no-op until plugin API stabilizes). (PR #3)
- **Per-repo opt-in registry** — `scripts/eval/lib/registry.sh` manages `~/.config/opencode/eval-harness/registry.yaml`. Automated triggers (pre-push, sync-publish, stop-hook) skip when current repo isn't enabled. Required for 43-repo workspace support. (PR #4)
- **Per-(case,trigger) lockfile coordination** — `flock(1)` wraps the manifest+spawn+score critical section; mkdir-atomic fallback for flock-less platforms (macOS). `EVAL_LOCK_TIMEOUT` env (default 300s). (PR #5)
- **`pricing.json` + dollar cost reporting** — curated rates for haiku-3-5, sonnet-4-6, opus-4-7. Per-case `cost.usd` in results.json. Total at `summary.total_cost_usd`. Staleness warning (default 60 days); `EVAL_FAIL_ON_STALE_PRICING=1` to gate. (PR #6)
- **3-sample stability on critical path** — `--stability-samples=N` flag + `EVAL_STABILITY_SAMPLES` env. On FAIL, runs N-1 more samples. Records byte-identicity. Tags attribution `flaky:true` when samples diverge. (PR #7)

### Changed
- `lib/yq-shim.sh` (`_yq.py`) now handles `-o=json` argv form, `[]?` iteration suffix, and `// []` fallback for empty lists.
- `lib/diff.sh` results schema gains `.cases[i].cost`, `.cases[i].stability`, `.summary.total_cost_usd`.

### Verified
- 8 test suites all green: regression_inject, case_model_override, project_config, registry, lock_concurrency, pricing, stability_inline, stop_hook.
- v0.1.0 wire-format remains backward compatible (new fields are additive).

## [0.1.1] — 2026-05-29

### Fixed
- **spawn**: default model ID changed from `anthropic/claude-haiku-3-5` (invalid in opencode 1.15.10) to `anthropic/claude-3-5-haiku-latest`. The previous default caused every real run to 401 / "Model not found." Override remains via `EVAL_MODEL` or `OPENCODE_MODEL`. (commit `144c8e1`)
- **tests/regression_inject.sh**: demo skill path now resolves from multiple candidate roots (`REPO_ROOT/skills`, `$EVAL_HARNESS_DEMO_SKILL_DIR`, `$HOME/.config/opencode/skills`, alternate layout). Previously hard-coded to repo-root layout, which failed when installed into a user's `~/.config/opencode/`. (commit `dffdc99`)

### Documentation
- **README**: explicit factors list + review/eval workflow. Three new sections:
  - "What this harness scores (the factors)" — three layers (5 check kinds + 4 attribution fields + deferred design review) with reliability column
  - "The review workflow" — two Mermaid flowcharts showing exactly which factors fire at git pre-push vs sync-publish gates, plus an explicit "does NOT enforce" table
  - "How to verify the harness is actually running these factors" — three reproducible commands scoped per layer
  - (commit `2e8de78`)
- **standards/skill-quality-v1.md**: SQS-1 re-framed as draft heuristic (not a published standard). Adds reliability-disclosure block at the top distinguishing:
  - Tier 1 (13 checks, 🟢): grounded in Anthropic Skills doc + OWASP + MCP conventions
  - Tier 2 (7 checks, 🟡): industry pattern, threshold unspecified
  - Tier 3 (10 checks, 🔴): author judgment from one-workspace pattern matching, needs validation
  - Each check row in categories A–G now carries an inline tier tag. (commit `8c6412c`)

### Verified end-to-end
- `npm test` runs `scripts/eval/tests/regression_inject.sh` with all 5 acceptance assertions green: verdict=REGRESSION, attribution=SKILL_CHANGED, regression list non-empty, failed_check_id populated, warn-only exit 0.
- Real opencode 1.15.10 run executes 3 cases end-to-end, produces valid 6-field FAIL output. (Authentication failures in some environments are environment-credential issues, not harness defects.)

### Unchanged from v0.1.0
- API surface (`run`, `baseline`, `accept`, `status`, `promote`, `trend`)
- 6-field FAIL schema, 4-class attribution, opt-in publish gate, warn-only-by-default mode
- All 18 Settled Decisions from the Design Brief — 15 fully implemented, 3 partial (3-sample stability on critical path, pricing.json staleness gate, per-(case,trigger) lockfile) deferred to v0.2.0

## [0.1.0] — 2026-05-28

Initial release.

### Added
- Bash-first eval harness for opencode skills. Five check kinds (`shell`, `jq_path_contains`, `file_exists`, `output_contains`, `output_not_contains`). Four-class attribution. Six-field FAIL schema. Two triggers (git pre-push, sync-skill-to-manager pre-publish). One canonical demo (`npm test`).
- Designed via the `deep-design` multi-agent pipeline (Metis + Oracle + cross-critique + Momus synthesis). See README for full architecture.

### Known limitations
- Structured-output skills only (prose deferred to v0.3 LLM judge)
- Deterministic mode only (T=0, k=1; `pass@k` deferred to v0.2)
- opencode 1.15.10 lacks `--max-turns` / `--skills` / `--prompt-file` flags. Compensated via `timeout(1)` + ephemeral `OPENCODE_CONFIG_DIR`.
- 3-sample stability check coded but not on critical path
- `pricing.json` dollar conversion + staleness gate not yet shipped
- Per-(case,trigger) lockfile not implemented
