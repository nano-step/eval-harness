#!/usr/bin/env bash
# scripts/eval/run.sh — entrypoint. Executes one or more cases for a skill.
# Settled Decisions: 3-trigger model, single-tier in v0.1.0, ephemeral sandbox per case,
# run-all-checks, 3-sample stability on FAIL, exit code 12 on regression, 13 on harness error.

set -euo pipefail

_resolve_script_dir() {
  local src="${BASH_SOURCE[0]}"
  while [[ -L "$src" ]]; do
    local dir; dir="$(cd "$(dirname "$src")" && pwd)"
    src="$(readlink "$src")"
    [[ "$src" != /* ]] && src="$dir/$src"
  done
  cd "$(dirname "$src")" && pwd
}
RUN_SCRIPT_DIR="$(_resolve_script_dir)"
LIB="$RUN_SCRIPT_DIR/lib"
source "$LIB/yq-shim.sh"
source "$LIB/skills_root.sh"
source "$LIB/config.sh"
source "$LIB/registry.sh"
source "$LIB/lock.sh"
source "$LIB/runner.sh"
source "$LIB/preflight.sh"
source "$LIB/manifest.sh"
source "$LIB/spawn.sh"
source "$LIB/score.sh"
source "$LIB/diff.sh"
source "$LIB/stability.sh"
source "$LIB/pricing.sh"

VERSION="0.4.2"

usage() {
  cat <<'EOF'
eval-harness v$VERSION — opencode skill regression detector

Usage:
  eval-harness run [options]

Options:
  --skill=<name>          Skill to evaluate (looks in \$OPENCODE_SKILLS_ROOT)
  --case=<id>             Run only this case (default: all cases for skill)
  --trigger=<name>        Tag the run (manual|pre-push|sync-publish)
  --mode=<smoke|full|2tier>  smoke=cheap+samples=1, full=configured+samples=3,
                             2tier=smoke first, escalate to full on FAIL (default smoke)
  --debug                 Verbose log + keep sandbox dirs
  --pin-env=baseline      Re-run with baseline's env-manifest pinned
  --stability-samples=N   On FAIL re-run case N-1 more times; record byte-identicity (default 1)
  --runner=<name>         Runner adapter: opencode (default) | langgraph-node | <custom>
                          A case YAML's `runner:` must match this if both are set.
  --dry-run               Print plan; don't spawn opencode
  -h, --help              Show this help

2-tier defaults (override via env):
  EVAL_SMOKE_MODEL        anthropic/claude-3-5-haiku-latest
  EVAL_FULL_MODEL         \$EVAL_MODEL or anthropic/claude-sonnet-4-6
  EVAL_SMOKE_SAMPLES      1
  EVAL_FULL_SAMPLES       3

Environment:
  OPENCODE_SKILLS_ROOT     Override skills root. If unset: walks up from cwd
                           for .opencode/skills/, else \$HOME/.config/opencode/skills
  EVAL_BUDGET_USD          Daily hard cap (default: 2.00)
  EVAL_MAX_SECONDS         Per-case timeout (default: 180)
  EVAL_MODEL               Override model (default: anthropic/claude-haiku-3-5)
  EVAL_RUNNER              Default runner adapter (overridden per-case by case YAML `runner:`)
  EVAL_BYPASS              Set to 1 to skip evals (logged to history.ndjson)

Exit codes:
  0    All cases pass, no regression
  12   Regression detected (case flipped baseline=PASS to current=FAIL)
  13   Harness or scorer error
EOF
}

SKILL=""
CASE_ID=""
TRIGGER="manual"
DEBUG=0
DRY_RUN=0
PIN_ENV=""
MODE="${EVAL_MODE:-smoke}"
STABILITY_SAMPLES="${EVAL_STABILITY_SAMPLES:-1}"
RUNNER_OPT="${EVAL_RUNNER:-}"

for arg in "$@"; do
  case "$arg" in
    --skill=*)               SKILL="${arg#*=}" ;;
    --case=*)                CASE_ID="${arg#*=}" ;;
    --trigger=*)             TRIGGER="${arg#*=}" ;;
    --mode=*)                MODE="${arg#*=}" ;;
    --debug)                 DEBUG=1 ;;
    --dry-run)               DRY_RUN=1 ;;
    --pin-env=*)             PIN_ENV="${arg#*=}" ;;
    --stability-samples=*)   STABILITY_SAMPLES="${arg#*=}" ;;
    --runner=*)              RUNNER_OPT="${arg#*=}" ;;
    -h|--help)               usage; exit 0 ;;
    run)                     ;;
    *) echo "unknown arg: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

# Propagate --runner into the EVAL_RUNNER env var so the case loop can
# read it for per-invocation resolution. Empty means "use case YAML or
# fall back to opencode default".
if [[ -n "$RUNNER_OPT" ]]; then
  export EVAL_RUNNER="$RUNNER_OPT"
fi

case "$MODE" in
  smoke|full|2tier) ;;
  *) echo "[eval-harness] invalid --mode='$MODE' (smoke|full|2tier)" >&2; exit 2 ;;
esac

if ! [[ "$STABILITY_SAMPLES" =~ ^[1-9][0-9]*$ ]]; then
  echo "[eval-harness] invalid --stability-samples='$STABILITY_SAMPLES' (must be positive integer)" >&2
  exit 2
fi

apply_mode_defaults() {
  local mode="$1"
  case "$mode" in
    smoke)
      export EVAL_MODEL="${EVAL_SMOKE_MODEL:-anthropic/claude-3-5-haiku-latest}"
      export EVAL_LLM_JUDGE_SAMPLES="${EVAL_SMOKE_SAMPLES:-1}"
      ;;
    full)
      export EVAL_MODEL="${EVAL_FULL_MODEL:-${EVAL_MODEL:-anthropic/claude-sonnet-4-6}}"
      export EVAL_LLM_JUDGE_SAMPLES="${EVAL_FULL_SAMPLES:-3}"
      ;;
  esac
}

if [[ -z "$SKILL" ]]; then
  echo "error: --skill=<name> is required" >&2
  usage >&2
  exit 2
fi

STATE_DIR="${EVAL_STATE_DIR:-$HOME/.config/opencode/eval-harness}"
mkdir -p "$STATE_DIR/locks" "$STATE_DIR/runs"
HISTORY_LOG="$STATE_DIR/history.ndjson"
touch "$HISTORY_LOG"

log_bypass_event() {
  local skill="$1"; local trigger="$2"
  jq -n --arg ts "$(date -u +%FT%TZ)" --arg s "$skill" --arg t "$trigger" \
    '{event:"bypass", timestamp:$ts, skill:$s, trigger:$t}' >> "$HISTORY_LOG"
}

if [[ "${EVAL_BYPASS:-0}" == "1" ]]; then
  echo "[eval-harness] EVAL_BYPASS=1 — skipping eval, logging bypass" >&2
  log_bypass_event "$SKILL" "$TRIGGER"
  exit 0
fi

apply_project_config

if [[ "$MODE" == "2tier" ]]; then
  exec bash "$RUN_SCRIPT_DIR/twotier.sh" "$@"
fi

if [[ "$MODE" == "smoke" || "$MODE" == "full" ]]; then
  apply_mode_defaults "$MODE"
fi

case "$TRIGGER" in
  pre-push|sync-publish|stop-hook)
    repo_name="$(repo_name_from_path "$(pwd)")"
    if ! registry_is_enabled "$repo_name"; then
      echo "[eval-harness] repo '$repo_name' not in registry — skipping ($TRIGGER trigger)" >&2
      echo "[eval-harness] enable with: bash scripts/eval/lib/registry.sh enable $repo_name" >&2
      exit 0
    fi
    ;;
esac

# Pre-scan case files to determine which runners are needed, then run
# preflight for each. This handles mixed-runner case sets where the CLI
# didn't pin --runner: e.g., one opencode case + one langgraph-node case
# should preflight both, not fail on the first preflight_check.
declare -A _NEEDED_RUNNERS=()
for _cf in "${CASE_FILES[@]}"; do
  [[ -f "$_cf" ]] || continue
  _cr="$(yq -r '.runner // "opencode"' "$_cf" 2>/dev/null || echo "opencode")"
  _NEEDED_RUNNERS["$_cr"]=1
done
for _r in "${!_NEEDED_RUNNERS[@]}"; do
  case "$_r" in
    opencode)       if ! preflight_check;          then exit 13; fi ;;
    langgraph-node) if ! preflight_check_langgraph; then exit 13; fi ;;
    *)
      echo "[eval-harness] unknown runner '$_r' in case files" >&2
      exit 13
      ;;
  esac
done
unset _NEEDED_RUNNERS _cr _cf _r

SKILLS_ROOT="$(resolve_skills_root)"
SKILL_DIR="$SKILLS_ROOT/$SKILL"
EVALS_DIR="$SKILL_DIR/evals"
CASES_DIR="$EVALS_DIR/cases"
BASELINES_DIR="$EVALS_DIR/baselines"
FIXTURES_DIR="$EVALS_DIR/fixtures"

if [[ ! -d "$CASES_DIR" ]]; then
  echo "[eval-harness] no evals found for skill '$SKILL' at $CASES_DIR" >&2
  exit 0
fi

RUN_ID="$(date -u +%Y-%m-%dT%H-%M-%SZ)-$RANDOM"
RUN_DIR="$STATE_DIR/runs/$RUN_ID"
mkdir -p "$RUN_DIR"

if [[ -n "$CASE_ID" ]]; then
  CASE_FILES=("$CASES_DIR/$CASE_ID.yaml")
else
  mapfile -t CASE_FILES < <(find "$CASES_DIR" -maxdepth 1 -type f -name "*.yaml" | sort)
fi

if [[ ${#CASE_FILES[@]} -eq 0 ]]; then
  echo "[eval-harness] no case files matched for skill=$SKILL case=$CASE_ID" >&2
  exit 0
fi

echo "[eval-harness] v$VERSION trigger=$TRIGGER skill=$SKILL cases=${#CASE_FILES[@]}"
echo "[eval-harness] run_id=$RUN_ID"

PRICING_STALENESS="$(pricing_staleness_check)"
PRICING_STATUS="$(echo "$PRICING_STALENESS" | jq -r '.status')"
case "$PRICING_STATUS" in
  STALE)
    echo "[eval-harness] WARN: $(echo "$PRICING_STALENESS" | jq -r '.message')" >&2
    if [[ "${EVAL_FAIL_ON_STALE_PRICING:-0}" == "1" ]]; then
      echo "[eval-harness] EVAL_FAIL_ON_STALE_PRICING=1 — refusing to run" >&2
      exit 13
    fi
    ;;
  MISSING|INVALID)
    echo "[eval-harness] note: pricing data $PRICING_STATUS — cost data will be null" >&2
    ;;
esac

case_results=()
i=0
for case_file in "${CASE_FILES[@]}"; do
  i=$((i+1))
  if [[ ! -f "$case_file" ]]; then
    echo "[eval-harness] case file missing: $case_file" >&2
    continue
  fi

  cid="$(yq -r '.id' "$case_file")"
  prompt="$(yq -r '.prompt' "$case_file")"
  description="$(yq -r '.description // ""' "$case_file")"
  mapfile -t skills_loaded < <(yq -r '.skills_loaded[]' "$case_file" 2>/dev/null || true)
  [[ ${#skills_loaded[@]} -eq 0 ]] && skills_loaded=("$SKILL")

  case_model="$(yq -r '.model // ""' "$case_file" 2>/dev/null || echo "")"
  if [[ -n "$case_model" ]]; then
    export EVAL_CASE_MODEL="$case_model"
  else
    unset EVAL_CASE_MODEL
  fi

  # Per-invocation runner resolution (KTD1):
  #   1. CLI --runner sets EVAL_RUNNER. If case has runner:, they must match (skip on mismatch).
  #   2. Case runner: is the per-case default.
  #   3. Neither set: default to "opencode" (KTD2).
  case_runner="$(yq -r '.runner // ""' "$case_file" 2>/dev/null || echo "")"
  if [[ -n "$case_runner" ]]; then
    if [[ -n "${EVAL_RUNNER:-}" && "${EVAL_RUNNER}" != "$case_runner" ]]; then
      echo "[eval-harness] case $cid: runner mismatch (CLI=$EVAL_RUNNER case=$case_runner) — skipping" >&2
      continue
    fi
    EFFECTIVE_RUNNER="$case_runner"
  elif [[ -n "${EVAL_RUNNER:-}" ]]; then
    EFFECTIVE_RUNNER="$EVAL_RUNNER"
  else
    EFFECTIVE_RUNNER="opencode"
  fi
  export EVAL_RUNNER="$EFFECTIVE_RUNNER"

  # Per-case preflight: opencode is already preflighted above (re-run is
  # idempotent). For langgraph-node and future non-opencode runners, run
  # the runner-specific preflight here.
  case "$EFFECTIVE_RUNNER" in
    opencode) ;;
    langgraph-node)
      if ! preflight_check_langgraph; then
        echo "[eval-harness] case $cid: preflight failed for runner=$EFFECTIVE_RUNNER — skipping" >&2
        continue
      fi
      ;;
    *)
      echo "[eval-harness] case $cid: unknown runner '$EFFECTIVE_RUNNER' — skipping" >&2
      continue
      ;;
  esac

  if [[ "$DRY_RUN" == "1" ]]; then
    echo "[eval-harness] [dry-run] case $i/${#CASE_FILES[@]} $cid runner=$EFFECTIVE_RUNNER"
    continue
  fi

  per_case_dir="$RUN_DIR/$cid"
  mkdir -p "$per_case_dir"
  workdir="$per_case_dir/workdir"
  sandbox="$per_case_dir/sandbox"
  mkdir -p "$workdir"

  fixture_error=0
  while IFS=$'\t' read -r dest src; do
    [[ -z "$dest" ]] && continue

    if [[ "$dest" = /* ]] || [[ "$dest" == *..* ]]; then
      echo "[eval-harness] case $cid: rejecting fixture dest='$dest' (absolute or contains '..')" >&2
      fixture_error=1
      break
    fi

    src_path="$src"
    if [[ "$src" != /* ]]; then
      src_path="$EVALS_DIR/$src"
    fi

    full_dest="$workdir/$dest"
    canonical_dest="$(python3 -c "import os,sys; print(os.path.normpath(sys.argv[1]))" "$full_dest")"
    canonical_workdir="$(python3 -c "import os,sys; print(os.path.normpath(sys.argv[1]))" "$workdir")"
    if [[ "$canonical_dest" != "$canonical_workdir"/* && "$canonical_dest" != "$canonical_workdir" ]]; then
      echo "[eval-harness] case $cid: rejecting fixture dest='$dest' — resolves outside workdir" >&2
      fixture_error=1
      break
    fi

    if ! mkdir -p "$(dirname "$full_dest")"; then
      echo "[eval-harness] case $cid: mkdir failed for $(dirname "$full_dest")" >&2
      fixture_error=1
      break
    fi
    if [[ -f "$src_path" ]]; then
      if ! cp "$src_path" "$full_dest"; then
        echo "[eval-harness] case $cid: cp failed: $src_path -> $full_dest" >&2
        fixture_error=1
        break
      fi
    else
      echo "[eval-harness] case $cid: fixture source missing: $src_path" >&2
    fi
  done < <(yq -o=json '.setup.fixtures // {}' "$case_file" | jq -r 'to_entries[] | "\(.key)\t\(.value)"')

  if [[ "$fixture_error" == "1" ]]; then
    echo "[eval-harness] case $cid: fixture errors — skipping case" >&2
    continue
  fi

  export EVAL_FIXTURE_DIR="$FIXTURES_DIR"
  transcript="$per_case_dir/transcript.jsonl"

  lock_dir="$STATE_DIR/locks"
  mkdir -p "$lock_dir"
  lock_key="$(printf '%s' "$SKILL:$cid:$TRIGGER" | tr '/ ' '__')"
  lock_file="$lock_dir/$lock_key.lock"
  lock_timeout="${EVAL_LOCK_TIMEOUT:-300}"

  exec 9>"$lock_file"
  if command -v flock >/dev/null 2>&1; then
    if ! flock -w "$lock_timeout" -x 9; then
      echo "[eval-harness] lock timeout (${lock_timeout}s) on $SKILL:$cid:$TRIGGER — another run holds it" >&2
      exec 9>&-
      continue
    fi
  else
    mkdir_lock="${lock_file}.d"
    waited=0
    while ! mkdir "$mkdir_lock" 2>/dev/null; do
      if [[ "$waited" -ge "$lock_timeout" ]]; then
        echo "[eval-harness] mkdir-lock timeout (${lock_timeout}s) on $SKILL:$cid:$TRIGGER" >&2
        exec 9>&-
        continue 2
      fi
      sleep 1
      waited=$((waited+1))
    done
  fi

  # Compute runner-aware manifest inputs (EVAL_RUNNER_CONFIG_SHA,
  # EVAL_GRAPH_FINGERPRINT) so capture_manifest picks them up.
  EVAL_RUNNER_CONFIG_SHA="none"
  EVAL_GRAPH_FINGERPRINT="none"
  if [[ "$EFFECTIVE_RUNNER" == "langgraph-node" ]]; then
    runner_config_json="$(yq -o=json '.runner_config // {}' "$case_file" 2>/dev/null || echo '{}')"
    EVAL_RUNNER_CONFIG_SHA="$(printf '%s' "$runner_config_json" | sha256sum | cut -d' ' -f1)"
    module_file="$(yq -r '.runner_config.module // "graph.py"' "$case_file" 2>/dev/null || echo "graph.py")"
    if [[ -f "$workdir/$module_file" ]]; then
      module_path="$workdir/$module_file"
    elif [[ -f "$FIXTURES_DIR/$module_file" ]]; then
      module_path="$FIXTURES_DIR/$module_file"
    else
      module_path=""
    fi
    if [[ -n "$module_path" && -f "$module_path" ]]; then
      EVAL_GRAPH_FINGERPRINT="$(dispatch_runner fingerprint langgraph-node "$module_path" 2>/dev/null || echo none)"
    fi
  fi
  export EVAL_RUNNER_CONFIG_SHA EVAL_GRAPH_FINGERPRINT

  capture_manifest "$SKILL" "$per_case_dir/env-manifest.json"

  case "$EFFECTIVE_RUNNER" in
    opencode)
      if command -v opencode >/dev/null 2>&1; then
        exit_code="$(spawn_runner opencode "$prompt" "$workdir" "$sandbox" "$transcript" "${skills_loaded[@]}")"
      else
        echo "[eval-harness] WARNING: opencode CLI not on PATH — emitting stub transcript for offline scoring" >&2
        : > "$transcript"
        exit_code=0
      fi
      ;;
    langgraph-node)
      input_file="$(yq -r '.runner_config.input // "input.json"' "$case_file" 2>/dev/null || echo "input.json")"
      output_file="$(yq -r '.runner_config.output // "output.json"' "$case_file" 2>/dev/null || echo "output.json")"
      exit_code="$(spawn_runner langgraph-node "$workdir" "$workdir/$input_file" "$workdir/$output_file" "$transcript")"
      ;;
  esac

  if [[ "$exit_code" == "124" ]]; then
    echo "[eval-harness] case $cid: opencode timed out after ${EVAL_MAX_SECONDS:-180}s (exit 124)" >&2
    jq -n \
      --arg cid "$cid" \
      --arg expected "opencode completes within ${EVAL_MAX_SECONDS:-180}s" \
      '{
        passed: false,
        total: 0,
        pass_count: 0,
        fail_count: 1,
        checks: [{
          kind: "harness_error",
          passed: false,
          failed_check_id: ("timeout:" + $cid),
          expected: $expected,
          actual: "timeout (exit 124)",
          diff_hint: "opencode was killed by timeout(1). Increase EVAL_MAX_SECONDS or check case prompt complexity.",
          error: true
        }]
      }' > "$per_case_dir/checks.json"
  elif [[ "$exit_code" != "0" ]] && [[ ! -s "$transcript" ]]; then
    echo "[eval-harness] case $cid: opencode exited $exit_code with empty transcript" >&2
    jq -n \
      --arg cid "$cid" \
      --arg actual "exit $exit_code, empty transcript" \
      '{
        passed: false,
        total: 0,
        pass_count: 0,
        fail_count: 1,
        checks: [{
          kind: "harness_error",
          passed: false,
          failed_check_id: ("spawn_failed:" + $cid),
          expected: "opencode produces transcript",
          actual: $actual,
          diff_hint: "opencode exited non-zero and wrote nothing. Check transcript.err for details.",
          error: true
        }]
      }' > "$per_case_dir/checks.json"
  else
    run_all_checks "$case_file" "$workdir" "$transcript" "$per_case_dir/checks.json"
  fi

  primary_passed="$(jq -r '.passed' "$per_case_dir/checks.json" 2>/dev/null || echo false)"
  stability_json='{"samples":1,"byte_identical":true,"hashes":[],"performed":false}'
  if [[ "$STABILITY_SAMPLES" -gt 1 && "$primary_passed" == "false" ]]; then
    echo "[eval-harness] case $cid FAILed — running $((STABILITY_SAMPLES - 1)) stability sample(s)" >&2
    hashes=("$(jq -S '.checks // []' "$per_case_dir/checks.json" 2>/dev/null | sha256sum | cut -d' ' -f1)")
    s=2
    while [[ "$s" -le "$STABILITY_SAMPLES" ]]; do
      sample_dir="$per_case_dir/stability/sample-$s"
      mkdir -p "$sample_dir"
      sample_workdir="$sample_dir/workdir"
      sample_sandbox="$sample_dir/sandbox"
      cp -R "$workdir" "$sample_workdir"
      sample_transcript="$sample_dir/transcript.jsonl"
      case "$EFFECTIVE_RUNNER" in
        opencode)
          if command -v opencode >/dev/null 2>&1; then
            spawn_runner opencode "$prompt" "$sample_workdir" "$sample_sandbox" "$sample_transcript" "${skills_loaded[@]}" >/dev/null
          else
            : > "$sample_transcript"
          fi
          ;;
        langgraph-node)
          input_file="$(yq -r '.runner_config.input // "input.json"' "$case_file" 2>/dev/null || echo "input.json")"
          output_file="$(yq -r '.runner_config.output // "output.json"' "$case_file" 2>/dev/null || echo "output.json")"
          spawn_runner langgraph-node "$sample_workdir" "$sample_workdir/$input_file" "$sample_workdir/$output_file" "$sample_transcript" >/dev/null
          ;;
      esac
      run_all_checks "$case_file" "$sample_workdir" "$sample_transcript" "$sample_dir/checks.json"
      hashes+=("$(jq -S '.checks // []' "$sample_dir/checks.json" 2>/dev/null | sha256sum | cut -d' ' -f1)")
      s=$((s+1))
    done
    first="${hashes[0]}"
    identical="true"
    for h in "${hashes[@]}"; do
      [[ "$h" != "$first" ]] && { identical="false"; break; }
    done
    hashes_json="$(printf '%s\n' "${hashes[@]}" | jq -R . | jq -s .)"
    stability_json="$(jq -n \
      --argjson samples "$STABILITY_SAMPLES" \
      --argjson identical "$identical" \
      --argjson hashes "$hashes_json" \
      '{samples:$samples, byte_identical:$identical, hashes:$hashes, performed:true}')"
    if [[ "$identical" == "false" ]]; then
      echo "[eval-harness] case $cid is FLAKY (samples diverged) — attribution will be tagged" >&2
    fi
  fi
  echo "$stability_json" > "$per_case_dir/stability.json"

  if ! command -v flock >/dev/null 2>&1; then
    rmdir "${lock_file}.d" 2>/dev/null || true
  fi
  exec 9>&-

  baseline_path="$BASELINES_DIR/$cid.baseline.json"
  case_result="$(SKILL_UNDER_TEST="$SKILL" build_case_result "$cid" "$per_case_dir" "$baseline_path")"
  case_results+=("$case_result")

  passed="$(echo "$case_result" | jq -r '.passed')"
  if [[ "$passed" == "true" ]]; then
    echo "[eval-harness] Case $i/${#CASE_FILES[@]} $cid PASS"
  else
    echo "[eval-harness] Case $i/${#CASE_FILES[@]} $cid FAIL"
  fi
done

if [[ "$DRY_RUN" == "1" ]]; then
  echo "[eval-harness] dry-run complete"
  exit 0
fi

results_array_json="$(printf '%s\n' "${case_results[@]}" | jq -s .)"
summary_json="$(build_run_summary "$results_array_json" "$RUN_ID" "$TRIGGER")"
echo "$summary_json" > "$RUN_DIR/results.json"
render_diff_md "$RUN_DIR/results.json" "$RUN_DIR/diff.md"

# Append a compact event line to history.ndjson (Settled #18)
jq -c --arg event run \
  '{event:$event, run_id:.run_id, trigger:.trigger, verdict:.verdict, summary:.summary}' \
  "$RUN_DIR/results.json" >> "$HISTORY_LOG"

verdict="$(jq -r '.verdict' "$RUN_DIR/results.json")"
pass="$(jq -r '.summary.pass' "$RUN_DIR/results.json")"
total="$(jq -r '.summary.total' "$RUN_DIR/results.json")"
regressions="$(jq -r '.regressions | join(", ")' "$RUN_DIR/results.json")"

case "$verdict" in
  PASS)
    echo "[eval-harness] PASS $pass/$total — see $RUN_DIR/diff.md"
    exit 0
    ;;
  REGRESSION)
    echo "[eval-harness] REGRESSION ($pass/$total) — regressions: $regressions"
    echo "[eval-harness] see $RUN_DIR/diff.md"
    # Warn-only check (Settled Decision #9 from prior brief, #15 in v2 brief)
    if [[ -f "$STATE_DIR/promoted" ]]; then
      echo "[eval-harness] EVAL_HARNESS_REGRESSION=1" >&2
      exit 12
    else
      echo "[eval-harness] WARN-ONLY MODE: exit 0. Promote with 'eval-harness promote' after 7 green days." >&2
      exit 0
    fi
    ;;
  FAIL)
    echo "[eval-harness] FAIL ($pass/$total) — no baseline diff to compare"
    echo "[eval-harness] see $RUN_DIR/diff.md"
    exit 0
    ;;
  *)
    echo "[eval-harness] ERROR: unknown verdict '$verdict'" >&2
    exit 13
    ;;
esac
