#!/usr/bin/env bash
# scripts/eval/rebaseline.sh — re-establish baselines under the current model (#EV-P0b).
# Re-runs the suite, rewrites baselines only for cases that STILL pass, and REFUSES any
# case that flipped PASS->FAIL — so a model upgrade cannot silently launder a regression.
# --accept-model-change overrides the refusal (for a genuine upgrade) and writes an audit
# record to history.ndjson. Baseline writes are atomic (temp + mv).

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
source "$SCRIPT_DIR/lib/stability.sh"   # inject_baseline_checksum (#EV-F)

usage() {
  cat <<EOF
Usage: eval-harness rebaseline --skill=<name> [--case=<id>] [--accept-model-change]

Re-runs the suite under the current model and rewrites baselines for cases that still PASS.
Refuses cases that flipped PASS->FAIL (exit 12) unless --accept-model-change is given, which
overrides and records a rebaseline audit event in history.ndjson.
EOF
}

SKILL=""; CASE_ID=""; OVERRIDE=0
for arg in "$@"; do
  case "$arg" in
    --skill=*) SKILL="${arg#*=}" ;;
    --case=*)  CASE_ID="${arg#*=}" ;;
    --accept-model-change) OVERRIDE=1 ;;
    -h|--help) usage; exit 0 ;;
    rebaseline) ;;
    *) echo "unknown arg: $arg" >&2; usage >&2; exit 2 ;;
  esac
done
[[ -z "$SKILL" ]] && { echo "error: --skill=<name> required" >&2; exit 2; }

STATE_DIR="${EVAL_STATE_DIR:-$HOME/.config/opencode/eval-harness}"
HISTORY="$STATE_DIR/history.ndjson"

# Re-run the suite and bind this operation to its own run id.
RUN_OUT_RAW="$("$SCRIPT_DIR/run.sh" --skill="$SKILL" ${CASE_ID:+--case=$CASE_ID} --trigger=rebaseline 2>&1 || true)"
printf '%s\n' "$RUN_OUT_RAW" >&2
RUN_ID="$(printf '%s\n' "$RUN_OUT_RAW" | sed -n 's/^\[eval-harness\] run_id=//p' | head -1)"
RUN_DIR="$STATE_DIR/runs/$RUN_ID"
[[ -n "$RUN_ID" && -f "$RUN_DIR/results.json" ]] || { echo "[eval-harness] rebaseline: no results for the run just executed" >&2; exit 13; }
run_verdict="$(jq -r '.verdict // "ERROR"' "$RUN_DIR/results.json")"
case "$run_verdict" in
  PASS) ;;
  REGRESSION) if [[ "$OVERRIDE" != "1" ]]; then echo "[eval-harness] rebaseline refuses PASS-to-FAIL changes without --accept-model-change" >&2; exit 12; fi ;;
  FAIL) if [[ "$OVERRIDE" != "1" ]]; then echo "[eval-harness] rebaseline requires PASS results; use --accept-model-change only for an intentional model upgrade" >&2; exit 14; fi ;;
  NEEDS_REVIEW) echo "[eval-harness] rebaseline requires completed human review" >&2; exit 15 ;;
  INDETERMINATE) echo "[eval-harness] rebaseline requires available evidence" >&2; exit 16 ;;
  *) echo "[eval-harness] rebaseline refuses run verdict $run_verdict" >&2; exit 13 ;;
esac
run_error_count="$(jq '[.cases[]? | select(.status=="ERROR")] | length' "$RUN_DIR/results.json")"
run_review_count="$(jq '[.cases[]? | select(.status=="NEEDS_REVIEW")] | length' "$RUN_DIR/results.json")"
run_indeterminate_count="$(jq '[.cases[]? | select(.status=="INDETERMINATE")] | length' "$RUN_DIR/results.json")"
if [[ "$run_error_count" -gt 0 ]]; then echo "[eval-harness] rebaseline refuses cases with harness errors" >&2; exit 13; fi
if [[ "$run_review_count" -gt 0 ]]; then echo "[eval-harness] rebaseline refuses pending human reviews" >&2; exit 15; fi
if [[ "$run_indeterminate_count" -gt 0 ]]; then echo "[eval-harness] rebaseline refuses unavailable evidence" >&2; exit 16; fi


SKILLS_ROOT="$(resolve_skills_root)"
BASELINES_DIR="$SKILLS_ROOT/$SKILL/evals/baselines"
mkdir -p "$BASELINES_DIR"

run_case_count="$(jq '[.cases[]?] | length' "$RUN_DIR/results.json")"
[[ "$run_case_count" -gt 0 ]] || { echo "[eval-harness] rebaseline: run has no cases" >&2; exit 13; }
while IFS= read -r case_json; do
  cid="$(printf '%s' "$case_json" | jq -r '.case_id')"
  baseline_path="$BASELINES_DIR/$cid.baseline.json"
  if [[ -f "$baseline_path" ]] && ! verify_baseline_integrity "$baseline_path"; then
    echo "[eval-harness] rebaseline: checksum mismatch in $baseline_path; refusing all writes" >&2
    exit 13
  fi
done < <(jq -c '.cases[]' "$RUN_DIR/results.json")
new_model_id="$(jq -r '.cases[0].env_manifest.model_id // "unknown"' "$RUN_DIR/results.json")"
old_model_id="unknown"
rewritten=0
refused=()

while read -r case_json; do
  cid="$(echo "$case_json" | jq -r '.case_id')"
  baseline_path="$BASELINES_DIR/$cid.baseline.json"
  cur_passed="$(echo "$case_json" | jq -r '.passed')"
  old_passed="null"; old_portable="false"
  if [[ -f "$baseline_path" ]]; then
    old_passed="$(jq -r '.passed' "$baseline_path" 2>/dev/null || echo null)"
    old_portable="$(jq -r '.env_manifest.portable // false' "$baseline_path" 2>/dev/null || echo false)"
    [[ "$old_model_id" == "unknown" ]] && old_model_id="$(jq -r '.env_manifest.model_id // "unknown"' "$baseline_path" 2>/dev/null || echo unknown)"
  fi

  # Refuse a genuine regression unless explicitly overridden.
  if [[ "$old_passed" == "true" && "$cur_passed" == "false" && "$OVERRIDE" != "1" ]]; then
    refused+=("$cid")
    echo "[eval-harness] rebaseline: REFUSING $cid — was PASS, now FAIL (use --accept-model-change to override)" >&2
    continue
  fi

  tmp="$baseline_path.tmp.$$"
  echo "$case_json" | jq --argjson portable "$( [[ "$old_portable" == "true" ]] && echo true || echo false )" --arg run_id "$RUN_ID" '{
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
    env_manifest: (if $portable then (.env_manifest + {portable: true}) else .env_manifest end),
    last_seen_triggers: ["rebaseline"]
  }' > "$tmp" && inject_baseline_checksum "$tmp" && mv "$tmp" "$baseline_path"
  rewritten=$((rewritten + 1))
  echo "[eval-harness] rebaseline: rewrote $cid" >&2
done < <(jq -c '.cases[]' "$RUN_DIR/results.json")

if [[ "$OVERRIDE" == "1" ]]; then
  touch "$HISTORY"
  jq -nc --arg ts "$(date -u +%FT%TZ)" --arg om "$old_model_id" --arg nm "$new_model_id" --argjson n "$rewritten" \
    '{event:"rebaseline", old_model_id:$om, new_model_id:$nm, cases_rewritten:$n, override:true, timestamp:$ts}' >> "$HISTORY"
  echo "[eval-harness] rebaseline: $rewritten rewritten under model '$new_model_id' (override; audit logged)"
  exit 0
fi

if [[ ${#refused[@]} -gt 0 ]]; then
  echo "[eval-harness] rebaseline: $rewritten rewritten, ${#refused[@]} refused (PASS->FAIL): ${refused[*]}" >&2
  echo "[eval-harness] resolve the regression(s) or re-run with --accept-model-change" >&2
  exit 12
fi

echo "[eval-harness] rebaseline: $rewritten baseline(s) rewritten, none refused"
exit 0
