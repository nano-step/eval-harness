#!/usr/bin/env bash
# scripts/eval/run.sh — entrypoint. Executes one or more cases for a skill.
# Settled Decisions: 3-trigger model, single-tier in v0.1.0, ephemeral sandbox per case,
# run-all-checks, 3-sample stability on FAIL, exit code 12 on regression, 13 on harness error.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/lib"
source "$LIB/yq-shim.sh"
source "$LIB/skills_root.sh"
source "$LIB/config.sh"
source "$LIB/registry.sh"
source "$LIB/lock.sh"
source "$LIB/preflight.sh"
source "$LIB/manifest.sh"
source "$LIB/spawn.sh"
source "$LIB/score.sh"
source "$LIB/diff.sh"
source "$LIB/stability.sh"
source "$LIB/pricing.sh"

VERSION="0.1.0"

usage() {
  cat <<EOF
eval-harness v$VERSION — opencode skill regression detector

Usage:
  eval-harness run [options]

Options:
  --skill=<name>       Skill to evaluate (looks in \$OPENCODE_SKILLS_ROOT)
  --case=<id>          Run only this case (default: all cases for skill)
  --trigger=<name>     Tag the run (manual|pre-push|sync-publish)
  --debug              Verbose log + keep sandbox dirs
  --pin-env=baseline   Re-run with baseline's env-manifest pinned (for attribution)
  --dry-run            Print plan; don't spawn opencode
  -h, --help           Show this help

Environment:
  OPENCODE_SKILLS_ROOT     Override skills root. If unset: walks up from cwd
                           for .opencode/skills/, else \$HOME/.config/opencode/skills
  EVAL_BUDGET_USD          Daily hard cap (default: 2.00)
  EVAL_MAX_SECONDS         Per-case timeout (default: 180)
  EVAL_MODEL               Override model (default: anthropic/claude-haiku-3-5)
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

for arg in "$@"; do
  case "$arg" in
    --skill=*)    SKILL="${arg#*=}" ;;
    --case=*)     CASE_ID="${arg#*=}" ;;
    --trigger=*)  TRIGGER="${arg#*=}" ;;
    --debug)      DEBUG=1 ;;
    --dry-run)    DRY_RUN=1 ;;
    --pin-env=*)  PIN_ENV="${arg#*=}" ;;
    -h|--help)    usage; exit 0 ;;
    run)          ;;
    *) echo "unknown arg: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -z "$SKILL" ]]; then
  echo "error: --skill=<name> is required" >&2
  usage >&2
  exit 2
fi

# Bypass check (Settled #18: EVAL_BYPASS=1 logged but proceeds)
if [[ "${EVAL_BYPASS:-0}" == "1" ]]; then
  echo "[eval-harness] EVAL_BYPASS=1 — skipping eval, logging bypass" >&2
  log_bypass "$SKILL" "$TRIGGER"
  exit 0
fi

apply_project_config

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

if ! preflight_check; then
  exit 13
fi

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

STATE_DIR="${EVAL_STATE_DIR:-$HOME/.config/opencode/eval-harness}"
mkdir -p "$STATE_DIR/locks" "$STATE_DIR/runs"
HISTORY_LOG="$STATE_DIR/history.ndjson"
touch "$HISTORY_LOG"

log_bypass() {
  local skill="$1"; local trigger="$2"
  jq -n --arg ts "$(date -u +%FT%TZ)" --arg s "$skill" --arg t "$trigger" \
    '{event:"bypass", timestamp:$ts, skill:$s, trigger:$t}' >> "$HISTORY_LOG"
}

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

  if [[ "$DRY_RUN" == "1" ]]; then
    echo "[eval-harness] [dry-run] case $i/${#CASE_FILES[@]} $cid"
    continue
  fi

  per_case_dir="$RUN_DIR/$cid"
  mkdir -p "$per_case_dir"
  workdir="$per_case_dir/workdir"
  sandbox="$per_case_dir/sandbox"
  mkdir -p "$workdir"

  # Materialize fixtures into the workdir (Settled Decision #9)
  yq -o=json '.setup.fixtures // {}' "$case_file" | jq -r 'to_entries[] | "\(.key)\t\(.value)"' | while IFS=$'\t' read -r dest src; do
    src_path="$src"
    if [[ "$src" != /* ]]; then
      src_path="$EVALS_DIR/$src"
    fi
    mkdir -p "$(dirname "$workdir/$dest")"
    if [[ -f "$src_path" ]]; then
      cp "$src_path" "$workdir/$dest"
    fi
  done

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

  capture_manifest "$SKILL" "$per_case_dir/env-manifest.json"

  if command -v opencode >/dev/null 2>&1; then
    exit_code="$(spawn_opencode "$prompt" "$workdir" "$sandbox" "$transcript" "${skills_loaded[@]}")"
  else
    echo "[eval-harness] WARNING: opencode CLI not on PATH — emitting stub transcript for offline scoring" >&2
    : > "$transcript"
    exit_code=0
  fi

  run_all_checks "$case_file" "$workdir" "$transcript" "$per_case_dir/checks.json"

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
