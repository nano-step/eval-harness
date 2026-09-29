#!/usr/bin/env bash
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
RUN_BIN="$SCRIPT_DIR/run.sh"

usage() {
  cat <<EOF
eval-harness twotier — smoke then escalate-to-full on FAIL

Usage:
  twotier.sh --skill=<name> [--case=<id>] [--trigger=<name>]

Env:
  EVAL_SMOKE_MODEL        default: anthropic/claude-3-5-haiku-latest
  EVAL_SMOKE_SAMPLES      default: 1
  EVAL_FULL_MODEL         default: anthropic/claude-sonnet-4-6
  EVAL_FULL_SAMPLES       default: 3

Exit codes:
  0   smoke PASS, warn-only outcome, or full pass cleared every smoke-FAIL
  12  full pass confirmed at least one regression
  13  harness error
  14  strict measured failure
  15  strict pending human review
  16  strict unavailable evidence
EOF
}

ARGS=()
SKILL=""
CASE_ID=""
STRICT="${EVAL_STRICT:-0}"
for arg in "$@"; do
  case "$arg" in
    --skill=*) SKILL="${arg#*=}"; ARGS+=("$arg") ;;
    --case=*)  CASE_ID="${arg#*=}"; ARGS+=("$arg") ;;
    --strict)  STRICT=1; ARGS+=("$arg") ;;
    -h|--help) usage; exit 0 ;;
    *) ARGS+=("$arg") ;;
  esac
done

if [[ -z "$SKILL" ]]; then
  echo "twotier: --skill=<name> required" >&2
  usage >&2
  exit 2
fi

STATE_DIR="${EVAL_STATE_DIR:-$HOME/.config/opencode/eval-harness}"

echo "[twotier] === SMOKE pass ==="
SMOKE_BEFORE="$(ls -1d "$STATE_DIR/runs"/* 2>/dev/null | wc -l | tr -d ' ' || echo 0)"
EVAL_MODE=smoke bash "$RUN_BIN" "${ARGS[@]}" --mode=smoke || smoke_rc=$?
smoke_rc="${smoke_rc:-0}"

SMOKE_RUN="$(ls -dt "$STATE_DIR/runs"/* 2>/dev/null | head -1 || true)"
SMOKE_AFTER="$(ls -1d "$STATE_DIR/runs"/* 2>/dev/null | wc -l | tr -d ' ' || echo 0)"

if [[ "$SMOKE_AFTER" -le "$SMOKE_BEFORE" ]] || [[ -z "$SMOKE_RUN" || ! -f "$SMOKE_RUN/results.json" ]]; then
  echo "[twotier] smoke produced no new results — bailing with smoke exit code $smoke_rc" >&2
  exit "${smoke_rc:-13}"
fi

smoke_verdict="$(jq -r '.verdict' "$SMOKE_RUN/results.json")"
if [[ "$smoke_verdict" == "PASS" ]]; then
  echo "[twotier] smoke PASS — no full pass needed."
  exit 0
fi

failed_cases="$(jq -r '[.cases[] | select(.status == "FAIL" or (.status == null and .passed == false)) | .case_id] | join(",")' "$SMOKE_RUN/results.json")"
if [[ -z "$failed_cases" ]]; then
  echo "[twotier] no failed cases to escalate — exiting"
  exit "$smoke_rc"
fi

echo "[twotier] === FULL pass on $(echo "$failed_cases" | tr ',' '\n' | wc -l | tr -d ' ') failed case(s): $failed_cases ==="

AGG_DIR="$STATE_DIR/runs/2tier-$(date -u +%Y-%m-%dT%H-%M-%SZ)-$$"
mkdir -p "$AGG_DIR"
AGG_RUN_IDS=("$(basename "$SMOKE_RUN")")
FULL_CASE_RESULTS=()

IFS=',' read -ra cases_arr <<<"$failed_cases"
for c in "${cases_arr[@]}"; do
  echo "[twotier]   escalating case=$c"
  FULL_ARGS=(--skill="$SKILL" --case="$c" --mode=full --trigger=2tier-escalation)
  [[ "$STRICT" != "1" ]] || FULL_ARGS+=(--strict)
  EVAL_MODE=full bash "$RUN_BIN" "${FULL_ARGS[@]}" || true
  full_run="$(ls -dt "$STATE_DIR/runs"/* 2>/dev/null | head -1)"
  if [[ -z "$full_run" || ! -f "$full_run/results.json" ]]; then
    echo "[twotier]   case $c: full pass produced no results" >&2
    FULL_CASE_RESULTS+=("$(jq -n --arg c "$c" '{case_id:$c, passed:false, baseline_passed:null, full_pass_error:true, attribution:{top:"HARNESS_ERROR"}}')")
    continue
  fi
  AGG_RUN_IDS+=("$(basename "$full_run")")
  case_result="$(jq -c '.cases[] | select(.case_id == "'"$c"'")' "$full_run/results.json")"
  if [[ -z "$case_result" ]]; then
    case_result="$(jq -n --arg c "$c" '{case_id:$c, passed:false, baseline_passed:null, full_pass_error:true}')"
  fi
  FULL_CASE_RESULTS+=("$case_result")
done

full_pass_count=0
full_fail_count=0
full_error_count=0
full_review_count=0
full_indeterminate_count=0
full_regression_ids=()
for r in "${FULL_CASE_RESULTS[@]}"; do
  status="$(echo "$r" | jq -r '.status // (if .full_pass_error then "ERROR" elif .passed == true then "PASS" else "FAIL" end)')"
  baseline_passed="$(echo "$r" | jq -r '.baseline_passed // "null"')"
  case_id="$(echo "$r" | jq -r '.case_id')"
  case "$status" in
    PASS) full_pass_count=$((full_pass_count + 1)) ;;
    FAIL)
      full_fail_count=$((full_fail_count + 1))
      [[ "$baseline_passed" != "true" ]] || full_regression_ids+=("$case_id") ;;
    ERROR) full_error_count=$((full_error_count + 1)) ;;
    NEEDS_REVIEW) full_review_count=$((full_review_count + 1)) ;;
    INDETERMINATE) full_indeterminate_count=$((full_indeterminate_count + 1)) ;;
    *) full_error_count=$((full_error_count + 1)) ;;
  esac
done

agg_verdict="PASS"
if [[ "$full_error_count" -gt 0 ]]; then
  agg_verdict="ERROR"
elif [[ "$full_review_count" -gt 0 ]]; then
  agg_verdict="NEEDS_REVIEW"
elif [[ "$full_indeterminate_count" -gt 0 ]]; then
  agg_verdict="INDETERMINATE"
elif [[ "${#full_regression_ids[@]}" -gt 0 ]]; then
  agg_verdict="REGRESSION"
elif [[ "$full_fail_count" -gt 0 ]]; then
  agg_verdict="FAIL"
fi

full_cases_json="$(printf '%s\n' "${FULL_CASE_RESULTS[@]}" | jq -s .)"
regressions_json="$(printf '%s\n' "${full_regression_ids[@]:-}" | jq -R . | jq -s 'map(select(. != ""))')"
run_ids_json="$(printf '%s\n' "${AGG_RUN_IDS[@]}" | jq -R . | jq -s .)"

jq -n --arg verdict "$agg_verdict" --argjson smoke_results "$(cat "$SMOKE_RUN/results.json")" --argjson full_cases "$full_cases_json" --argjson regressions "$regressions_json" --argjson run_ids "$run_ids_json" --argjson pass "$full_pass_count" --argjson fail "$full_fail_count" --argjson errors "$full_error_count" --argjson needs_review "$full_review_count" --argjson indeterminate "$full_indeterminate_count" '{schema_version:2,mode:"2tier",verdict:$verdict,status:$verdict,summary:{smoke_total:$smoke_results.summary.total,smoke_pass:$smoke_results.summary.pass,smoke_fail:$smoke_results.summary.fail,full_escalated:($full_cases|length),full_pass:$pass,full_fail:$fail,full_error:$errors,needs_review:$needs_review,indeterminate:$indeterminate,regression_count:($regressions|length)},regressions:$regressions,contributing_run_ids:$run_ids,smoke_run:$smoke_results.run_id,full_cases:$full_cases}' > "$AGG_DIR/results.json"

echo "[twotier] aggregated result: $AGG_DIR/results.json"
echo "[twotier] verdict: $agg_verdict (smoke fail=$(jq -r '.summary.fail' "$SMOKE_RUN/results.json"), full pass=$full_pass_count, full fail=$full_fail_count, regressions=${#full_regression_ids[@]})"

case "$agg_verdict" in
  PASS) exit 0 ;;
  REGRESSION) exit 12 ;;
  FAIL) [[ "$STRICT" == "1" ]] && exit 14 || exit 0 ;;
  ERROR) exit 13 ;;
  NEEDS_REVIEW) [[ "$STRICT" == "1" ]] && exit 15 || exit 0 ;;
  INDETERMINATE) [[ "$STRICT" == "1" ]] && exit 16 || exit 0 ;;
  *) exit 13 ;;
esac
