# Changelog

All notable changes to `@nano-step/eval-harness` are documented here.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/);
this project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
