#!/usr/bin/env bash
# scripts/eval/baseline.sh — write/refresh baseline.json for a case or skill.
# Settled Decision #10: baseline writes only via explicit command (single-writer).
# Settled Decision #11: 3-sample stability check OK to skip on initial baseline.

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
SCRIPT_DIR="$(_resolve_script_dir)"
source "$SCRIPT_DIR/lib/manifest.sh"
source "$SCRIPT_DIR/lib/stability.sh"

usage() {
  cat <<EOF
Usage: eval-harness baseline --skill=<name> [--case=<id>] [--portable]

Runs the case(s) once, accepts current behavior as the baseline. Use only
when you intend to record the current output as the contract going forward.

If a baseline already exists, you must pass --force to overwrite.
EOF
}

SKILL=""; CASE_ID=""; FORCE=0; PORTABLE=0
for arg in "$@"; do
  case "$arg" in
    --skill=*) SKILL="${arg#*=}" ;;
    --case=*)  CASE_ID="${arg#*=}" ;;
    --force)   FORCE=1 ;;
    --portable) PORTABLE=1 ;;
    -h|--help) usage; exit 0 ;;
    baseline)  ;;
    *) echo "unknown arg: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -z "$SKILL" ]]; then
  echo "error: --skill=<name> required" >&2; exit 2
fi

# Capture this invocation's run id; never pick a concurrent process's globally newest run.
STATE_DIR="${EVAL_STATE_DIR:-$HOME/.config/opencode/eval-harness}"
RUN_OUT_RAW="$("$SCRIPT_DIR/run.sh" --skill="$SKILL" ${CASE_ID:+--case=$CASE_ID} --trigger=baseline 2>&1 || true)"
echo "$RUN_OUT_RAW"
RUN_ID="$(printf '%s\n' "$RUN_OUT_RAW" | sed -n 's/^\[eval-harness\] run_id=//p' | head -1)"
LATEST_RUN_DIR="$STATE_DIR/runs/$RUN_ID"
if [[ -z "$RUN_ID" || ! -f "$LATEST_RUN_DIR/results.json" ]]; then
  echo "[eval-harness] baseline: could not locate results for the run just executed" >&2
  exit 13
fi
run_verdict="$(jq -r '.verdict // "ERROR"' "$LATEST_RUN_DIR/results.json")"
case "$run_verdict" in
  PASS) ;;
  FAIL) echo "[eval-harness] baseline requires PASS; run verdict was FAIL" >&2; exit 14 ;;
  REGRESSION) echo "[eval-harness] baseline refuses regression results" >&2; exit 12 ;;
  NEEDS_REVIEW) echo "[eval-harness] baseline requires completed human review" >&2; exit 15 ;;
  INDETERMINATE) echo "[eval-harness] baseline requires available evidence" >&2; exit 16 ;;
  *) echo "[eval-harness] baseline refuses run verdict $run_verdict" >&2; exit 13 ;;
esac


source "$SCRIPT_DIR/lib/skills_root.sh"
source "$SCRIPT_DIR/lib/preflight.sh"

if ! preflight_check; then
  exit 13
fi

SKILLS_ROOT="$(resolve_skills_root)"
BASELINES_DIR="$SKILLS_ROOT/$SKILL/evals/baselines"
mkdir -p "$BASELINES_DIR"

# Write one baseline per case from the run
jq -c '.cases[]' "$LATEST_RUN_DIR/results.json" | while read -r case_json; do
  cid="$(echo "$case_json" | jq -r '.case_id')"
  baseline_path="$BASELINES_DIR/$cid.baseline.json"

  if [[ -f "$baseline_path" ]] && [[ "$FORCE" != "1" ]]; then
    echo "[eval-harness] baseline exists: $baseline_path (use --force to overwrite)"
    continue
  fi

  # --portable marks the baseline's env_manifest as making no model/opencode claim, so it
  # can be committed and consumed across machines without false-flagging MODEL_CHANGED
  # (diff_manifests strips only model_id+opencode_version for portable baselines).
  tmp_baseline="$baseline_path.tmp.$$"
  echo "$case_json" | jq --argjson portable "$PORTABLE" --arg run_id "$RUN_ID" '{
    schema_version: 3,
    case_id: .case_id,
    source_run_id: $run_id,
    passed: .passed,
    status: .status,
    eval_type: .evaluation_type,
    compare_to_baseline: .compare_to_baseline,
    checks: .checks,
    quality: .quality,
    reliability: .reliability,
    resources: .resources,
    grading_manifest: .grading_manifest,
    env_manifest: (if $portable == 1 then (.env_manifest + {portable: true}) else .env_manifest end),
    last_seen_triggers: ["baseline"]
  }' > "$tmp_baseline"
  inject_baseline_checksum "$tmp_baseline"
  mv "$tmp_baseline" "$baseline_path"
  echo "[eval-harness] wrote baseline: $baseline_path$([[ "$PORTABLE" == "1" ]] && echo ' (portable)')"
done
