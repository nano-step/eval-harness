#!/usr/bin/env bash
# scripts/eval/baseline.sh — write/refresh baseline.json for a case or skill.
# Settled Decision #10: baseline writes only via explicit command (single-writer).
# Settled Decision #11: 3-sample stability check OK to skip on initial baseline.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/manifest.sh"

usage() {
  cat <<EOF
Usage: eval-harness baseline --skill=<name> [--case=<id>]

Runs the case(s) once, accepts current behavior as the baseline. Use only
when you intend to record the current output as the contract going forward.

If a baseline already exists, you must pass --force to overwrite.
EOF
}

SKILL=""; CASE_ID=""; FORCE=0
for arg in "$@"; do
  case "$arg" in
    --skill=*) SKILL="${arg#*=}" ;;
    --case=*)  CASE_ID="${arg#*=}" ;;
    --force)   FORCE=1 ;;
    -h|--help) usage; exit 0 ;;
    baseline)  ;;
    *) echo "unknown arg: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -z "$SKILL" ]]; then
  echo "error: --skill=<name> required" >&2; exit 2
fi

# Run the suite first, capture results
RUN_OUT_RAW="$("$SCRIPT_DIR/run.sh" --skill="$SKILL" ${CASE_ID:+--case=$CASE_ID} --trigger=baseline 2>&1 || true)"
echo "$RUN_OUT_RAW"

LATEST_RUN_DIR="$(ls -dt "${EVAL_STATE_DIR:-$HOME/.config/opencode/eval-harness}/runs"/* 2>/dev/null | head -1)"
if [[ -z "$LATEST_RUN_DIR" ]] || [[ ! -f "$LATEST_RUN_DIR/results.json" ]]; then
  echo "[eval-harness] baseline: could not locate the run that just executed" >&2
  exit 13
fi

SKILLS_ROOT="${OPENCODE_SKILLS_ROOT:-$HOME/.config/opencode/skills}"
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

  echo "$case_json" | jq '{
    schema_version: 2,
    case_id: .case_id,
    passed: .passed,
    checks: .checks,
    env_manifest: .env_manifest,
    last_seen_triggers: ["baseline"]
  }' > "$baseline_path"
  echo "[eval-harness] wrote baseline: $baseline_path"
done
