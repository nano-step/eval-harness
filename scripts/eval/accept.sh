#!/usr/bin/env bash
# Accept one verified PASS result as a baseline. Use --run to select an exact run.
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
source "$SCRIPT_DIR/lib/skills_root.sh"
source "$SCRIPT_DIR/lib/stability.sh"

usage() {
  cat <<EOF
Usage: eval-harness accept --skill=<name> --case=<id> [--run=<run-id>] [--bless-env] [--yes]

Select a run explicitly with --run. Without it, the newest completed run containing this
skill/case is used. Acceptance requires the selected case to be PASS.
Without --bless-env, the old env_manifest is retained; with it, current provenance is accepted.
EOF
}

SKILL=""; CASE_ID=""; RUN_ID=""; BLESS_ENV=0; YES=0
for arg in "$@"; do
  case "$arg" in
    --skill=*) SKILL="${arg#*=}" ;;
    --case=*) CASE_ID="${arg#*=}" ;;
    --run=*) RUN_ID="${arg#*=}" ;;
    --bless-env) BLESS_ENV=1 ;;
    --yes) YES=1 ;;
    -h|--help) usage; exit 0 ;;
    accept) ;;
    *) echo "unknown arg: $arg" >&2; usage >&2; exit 2 ;;
  esac
done
[[ -n "$SKILL" && -n "$CASE_ID" ]] || { echo "error: --skill and --case required" >&2; exit 2; }

STATE_DIR="${EVAL_STATE_DIR:-$HOME/.config/opencode/eval-harness}"
SKILLS_ROOT="$(resolve_skills_root)"
BASELINE_PATH="$SKILLS_ROOT/$SKILL/evals/baselines/$CASE_ID.baseline.json"
LATEST_RUN_DIR=""
if [[ -n "$RUN_ID" ]]; then
  LATEST_RUN_DIR="$STATE_DIR/runs/$RUN_ID"
else
  while IFS= read -r candidate; do
    [[ -f "$candidate/results.json" ]] || continue
    if jq -e --arg c "$CASE_ID" --arg s "$SKILL" '[.cases[]? | select(.case_id==$c and (.env_manifest.skill_under_test // "")==$s)] | length>0' "$candidate/results.json" >/dev/null 2>&1; then
      LATEST_RUN_DIR="$candidate"
      RUN_ID="$(jq -r '.run_id' "$candidate/results.json")"
      break
    fi
  done < <(ls -dt "$STATE_DIR"/runs/* 2>/dev/null || true)
fi
if [[ -z "$RUN_ID" || ! -f "$LATEST_RUN_DIR/results.json" ]]; then
  echo "[eval-harness] accept: no matching run found; run the case first or pass --run=<run-id>" >&2
  exit 13
fi
if [[ "$(jq -r '.run_id' "$LATEST_RUN_DIR/results.json")" != "$RUN_ID" ]]; then
  echo "[eval-harness] accept: run id does not match the selected results file" >&2
  exit 13
fi
NEW_CASE="$(jq -c --arg c "$CASE_ID" --arg s "$SKILL" '.cases[]? | select(.case_id==$c and (.env_manifest.skill_under_test // "")==$s)' "$LATEST_RUN_DIR/results.json")"
if [[ -z "$NEW_CASE" ]]; then
  echo "[eval-harness] accept: case '$CASE_ID' for skill '$SKILL' is not in run '$RUN_ID'" >&2
  exit 2
fi
case_status="$(printf '%s' "$NEW_CASE" | jq -r '.status // (if .passed then "PASS" else "FAIL" end)')"
if [[ "$case_status" != "PASS" || "$(printf '%s' "$NEW_CASE" | jq -r '.passed == true')" != "true" ]]; then
  echo "[eval-harness] accept: requires a verified PASS result; selected case status is $case_status" >&2
  exit 14
fi
if [[ -f "$BASELINE_PATH" ]] && ! verify_baseline_integrity "$BASELINE_PATH"; then
  echo "[eval-harness] accept: existing baseline checksum mismatch; refusing to overwrite" >&2
  exit 13
fi

if [[ "$BLESS_ENV" == "1" && "$YES" != "1" ]]; then
  echo "WARNING: --bless-env updates model, runtime, skill, prompt, rubric and tool provenance in:" >&2
  echo "  $BASELINE_PATH" >&2
  read -r -p "Proceed? [y/N] " ans
  case "$ans" in y|Y|yes|YES) ;; *) echo "[eval-harness] aborted"; exit 1 ;; esac
fi

OLD_MANIFEST='{}'
if [[ "$BLESS_ENV" != "1" && -f "$BASELINE_PATH" ]]; then
  OLD_MANIFEST="$(jq -c '.env_manifest // {}' "$BASELINE_PATH")"
fi
mkdir -p "$(dirname "$BASELINE_PATH")"
tmp_baseline="$BASELINE_PATH.tmp.$$"
if [[ "$BLESS_ENV" == "1" ]]; then
  printf '%s' "$NEW_CASE" | jq --arg run_id "$RUN_ID" '{schema_version:3,case_id:.case_id,source_run_id:$run_id,passed:.passed,status:.status,eval_type:.evaluation_type,compare_to_baseline:.compare_to_baseline,checks:.checks,quality:.quality,reliability:.reliability,resources:.resources,grading_manifest:.grading_manifest,env_manifest:.env_manifest,last_seen_triggers:["accept-bless-env"]}' > "$tmp_baseline"
else
  printf '%s' "$NEW_CASE" | jq --arg run_id "$RUN_ID" --argjson old_env "$OLD_MANIFEST" '{schema_version:3,case_id:.case_id,source_run_id:$run_id,passed:.passed,status:.status,eval_type:.evaluation_type,compare_to_baseline:.compare_to_baseline,checks:.checks,quality:.quality,reliability:.reliability,resources:.resources,grading_manifest:.grading_manifest,env_manifest:$old_env,last_seen_triggers:["accept"]}' > "$tmp_baseline"
fi
inject_baseline_checksum "$tmp_baseline"
mv "$tmp_baseline" "$BASELINE_PATH"
if [[ "$BLESS_ENV" == "1" ]]; then
  echo "[eval-harness] accepted run $RUN_ID with env blessed: $BASELINE_PATH"
else
  echo "[eval-harness] accepted run $RUN_ID; env_manifest unchanged: $BASELINE_PATH"
  echo "[eval-harness] use --bless-env to update environment provenance"
fi
