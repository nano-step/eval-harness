#!/usr/bin/env bash
# scripts/eval/ab.sh — A/B skill comparison runner.
# Usage: ab.sh --base=<skill> --candidate=<skill> [--cases=<id,id,...>] [--trigger=<name>]
#
# Runs the same case set against two skills (base and candidate), then reports
# regressions (base PASS, candidate FAIL) and exits 12 if any exist.
# Writes machine-readable JSON to $STATE_DIR/runs/ab-<pid>/results.json.

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
eval-harness ab — side-by-side A/B skill comparison

Usage:
  ab.sh --base=<skill> --candidate=<skill> [--cases=<id,...>] [--base-model=<id>] [--candidate-model=<id>] [--warn-cost-increase-pct=<n>]

Options:
  --base=<skill>        Base skill name (the reference)
  --candidate=<skill>   Candidate skill name (the one being tested)
  --cases=<id,...>      Comma-separated case IDs (default: all cases)
  --base-model=<id>     Override base model for this side of the comparison
  --candidate-model=<id> Override candidate model for this side
  --warn-cost-increase-pct=<n> Warn when measured total cost increases by n percent; never gates
  --trigger=<name>      Tag the run (default: ab-compare)
  -h, --help            Show this help

Exit codes:
  0    Candidate passes every measured case and is equal or better
  12   Candidate regressed: base PASS -> candidate FAIL
  13   A side produced a harness error or a case was missing
  14   Candidate case failed without a base-PASS regression
  15   A required human review is pending
  16   Required evidence is indeterminate
  2    Bad arguments / usage error

Environment:
  EVAL_STATE_DIR        Where to write results (default: ~/.config/opencode/eval-harness)
  OPENCODE_SKILLS_ROOT  Override skills root
  EVAL_SKIP_AUTH_CHECK  Set to 1 for offline/stub testing
EOF
}

BASE=""
CANDIDATE=""
CASES_FILTER=""
TRIGGER="ab-compare"
BASE_MODEL=""
CANDIDATE_MODEL=""
COST_WARN_PCT=""

for arg in "$@"; do
  case "$arg" in
    --base=*)       BASE="${arg#*=}" ;;
    --candidate=*)  CANDIDATE="${arg#*=}" ;;
    --cases=*)      CASES_FILTER="${arg#*=}" ;;
    --base-model=*) BASE_MODEL="${arg#*=}" ;;
    --candidate-model=*) CANDIDATE_MODEL="${arg#*=}" ;;
    --warn-cost-increase-pct=*) COST_WARN_PCT="${arg#*=}" ;;
    --trigger=*)    TRIGGER="${arg#*=}" ;;
    -h|--help)      usage; exit 0 ;;
    *) echo "[ab] unknown argument: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -z "$BASE" ]]; then
  echo "[ab] error: --base=<skill> is required" >&2
  usage >&2
  exit 2
fi
if [[ -z "$CANDIDATE" ]]; then
  echo "[ab] error: --candidate=<skill> is required" >&2
  usage >&2
  exit 2
fi
if [[ -n "$COST_WARN_PCT" ]] && ! [[ "$COST_WARN_PCT" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  echo "[ab] --warn-cost-increase-pct must be a nonnegative number" >&2
  exit 2
fi
STATE_DIR="${EVAL_STATE_DIR:-$HOME/.config/opencode/eval-harness}"
mkdir -p "$STATE_DIR/runs"

# Use $$ for a unique directory (macOS-portable, no date -d, no flock required).
AB_RUN_ID="ab-$(date -u +%Y-%m-%dT%H-%M-%SZ)-$$"
AB_DIR="$STATE_DIR/runs/$AB_RUN_ID"
mkdir -p "$AB_DIR"

echo "[ab] base=$BASE candidate=$CANDIDATE trigger=$TRIGGER"
echo "[ab] results dir: $AB_DIR"

# ---------------------------------------------------------------------------
# Helper: run one skill (all cases or a filtered subset) and return the run dir.
# ---------------------------------------------------------------------------
_ab_error_case() {
  local case_id="$1" expected="$2" actual="$3" hint="$4"
  jq -n --arg cid "$case_id" --arg expected "$expected" --arg actual "$actual" --arg hint "$hint" '{case_id:$cid,passed:false,status:"ERROR",evaluation_type:"unknown",compare_to_baseline:false,baseline_passed:null,regression:false,checks:[{kind:"harness_error",passed:false,status:"ERROR",error:true,failed_check_id:("ab_run:"+$cid),expected:$expected,actual:$actual,diff_hint:$hint}],quality:{dimensions:{},aggregate:null},cost:{status:"unavailable",usd:null},resources:{tokens:{status:"unavailable",input_tokens:null,output_tokens:null},cost:{status:"unavailable",usd:null}}}'
}

_ab_invoke() {
  local skill="$1" model="$2"; shift 2
  if [[ -n "$model" ]]; then
    EVAL_MODEL="$model" EVAL_AB_MODEL_OVERRIDE="$model" EVAL_SMOKE_MODEL="$model" EVAL_FULL_MODEL="$model" bash "$RUN_BIN" "--skill=$skill" "--trigger=$TRIGGER" "$@" 2>&1 || true
  else
    bash "$RUN_BIN" "--skill=$skill" "--trigger=$TRIGGER" "$@" 2>&1 || true
  fi
}

run_skill() {
  local skill="$1" label="$2" model out_file
  out_file="$AB_DIR/${label}-results.json"
  if [[ "$label" == "base" ]]; then model="$BASE_MODEL"; else model="$CANDIDATE_MODEL"; fi
  echo "[ab] === running $label skill: $skill ===" >&2

  if [[ -z "$CASES_FILTER" ]]; then
    local run_output run_id run_dir
    run_output="$(_ab_invoke "$skill" "$model")"
    printf '%s\n' "$run_output" >&2
    run_id="$(printf '%s\n' "$run_output" | sed -n 's/^\[eval-harness\] run_id=//p' | head -1)"
    run_dir="$STATE_DIR/runs/$run_id"
    if [[ -n "$run_id" && -f "$run_dir/results.json" ]]; then
      jq --arg skill "$skill" --arg model "$model" '. + {ab_skill:$skill,model_override:(if $model=="" then null else $model end)}' "$run_dir/results.json" > "$out_file"
    else
      local error_case; error_case="$(_ab_error_case "__run__" "run results are written" "missing run result" "$label evaluation returned no run-id/results")"
      jq -n --arg label "$label" --arg skill "$skill" --arg model "$model" --argjson c "$error_case" '{schema_version:3,run_id:("ab-"+$label),trigger:"ab-compare",ab_skill:$skill,model_override:(if $model=="" then null else $model end),verdict:"ERROR",summary:{total:1,pass:0,fail:0,error:1,needs_review:0,indeterminate:0,total_cost_usd:null},regressions:[],cases:[$c]}' > "$out_file"
    fi
    return 0
  fi

  IFS=',' read -ra _case_ids <<< "$CASES_FILTER"
  local case_results_json='[]' total_pass=0 total_fail=0 total_error=0 total_review=0 total_indeterminate=0
  for cid in "${_case_ids[@]}"; do
    [[ -z "$cid" ]] && continue
    echo "[ab]   running case=$cid for $label" >&2
    local run_output run_id run_dir case_result status
    run_output="$(_ab_invoke "$skill" "$model" "--case=$cid")"
    printf '%s\n' "$run_output" >&2
    run_id="$(printf '%s\n' "$run_output" | sed -n 's/^\[eval-harness\] run_id=//p' | head -1)"
    run_dir="$STATE_DIR/runs/$run_id"
    case_result=""
    if [[ -n "$run_id" && -f "$run_dir/results.json" ]]; then
      case_result="$(jq -c --arg cid "$cid" '.cases[]? | select(.case_id==$cid)' "$run_dir/results.json" 2>/dev/null || true)"
    fi
    if [[ -z "$case_result" ]]; then
      case_result="$(_ab_error_case "$cid" "case result exists" "missing run result" "$label evaluation did not produce this case")"
    fi
    status="$(printf '%s' "$case_result" | jq -r '.status // (if .passed==true then "PASS" else "FAIL" end)')"
    case "$status" in
      PASS) total_pass=$((total_pass+1)) ;;
      FAIL) total_fail=$((total_fail+1)) ;;
      ERROR) total_error=$((total_error+1)) ;;
      NEEDS_REVIEW|PENDING) total_review=$((total_review+1)) ;;
      INDETERMINATE|UNAVAILABLE|ABSTAIN) total_indeterminate=$((total_indeterminate+1)) ;;
      *) total_error=$((total_error+1)); case_result="$(printf '%s' "$case_result" | jq '.status="ERROR" | .passed=false')" ;;
    esac
    case_results_json="$(printf '%s' "$case_results_json" | jq --argjson r "$case_result" '. + [$r]')"
  done

  local synth_run_id="ab-${label}-${skill}-$$" verdict cost_metrics total_cases
  total_cases="$(printf '%s' "$case_results_json" | jq 'length')"
  if [[ "$total_cases" -eq 0 || "$total_error" -gt 0 ]]; then verdict="ERROR"
  elif [[ "$total_review" -gt 0 ]]; then verdict="NEEDS_REVIEW"
  elif [[ "$total_indeterminate" -gt 0 ]]; then verdict="INDETERMINATE"
  elif [[ "$total_fail" -gt 0 ]]; then verdict="FAIL"
  else verdict="PASS"; fi
  cost_metrics="$(printf '%s' "$case_results_json" | jq '. as $cases | [.[].cost.usd | select(type=="number")] as $c | {status:(if ($c|length)==0 then "unavailable" elif ($c|length)==($cases|length) then "measured" else "partial" end),measured_cases:($c|length),total_cases:($cases|length),measured_subtotal_usd:(if ($c|length)==0 then null else ($c|add) end),total_usd:(if ($c|length)==($cases|length) and ($c|length)>0 then ($c|add) else null end)}')"
  jq -n --arg run_id "$synth_run_id" --arg trigger "$TRIGGER" --arg skill "$skill" --arg model "$model" --arg verdict "$verdict" \
    --argjson total "$total_cases" --argjson pass "$total_pass" --argjson fail "$total_fail" --argjson errors "$total_error" \
    --argjson review "$total_review" --argjson indeterminate "$total_indeterminate" --argjson cases "$case_results_json" --argjson cost "$cost_metrics" \
    '{schema_version:3,run_id:$run_id,trigger:$trigger,ab_skill:$skill,model_override:(if $model=="" then null else $model end),verdict:$verdict,summary:{total:$total,pass:$pass,fail:$fail,error:$errors,needs_review:$review,indeterminate:$indeterminate,total_cost_usd:$cost.total_usd,resources:{cost:$cost}},regressions:[],cases:$cases}' > "$out_file"
}


echo ""
run_skill "$BASE" "base"
BASE_RESULTS="$AB_DIR/base-results.json"

echo ""
run_skill "$CANDIDATE" "candidate"
CAND_RESULTS="$AB_DIR/candidate-results.json"

echo ""
echo "[ab] === comparing results ==="

# ---------------------------------------------------------------------------
# Build per-case comparison table.
# ---------------------------------------------------------------------------
# Collect all case IDs from both runs (union).
ALL_CASE_IDS="$(jq -r '[.cases[].case_id] | .[]' "$BASE_RESULTS" "$CAND_RESULTS" | sort -u)"

per_case_json="[]"
any_regression=0
any_error=0
any_review=0
any_indeterminate=0
any_candidate_fail=0
regression_count=0
improved_count=0
equal_count=0

printf "\n%-40s  %-15s  %-15s  %s\n" "CASE" "BASE" "CANDIDATE" "DELTA"
printf "%s\n" "--------------------------------------------------------------------------------"

while IFS= read -r cid; do
  [[ -z "$cid" ]] && continue
  base_result="$(jq -c --arg cid "$cid" '.cases[]? | select(.case_id==$cid)' "$BASE_RESULTS" 2>/dev/null || true)"
  candidate_result="$(jq -c --arg cid "$cid" '.cases[]? | select(.case_id==$cid)' "$CAND_RESULTS" 2>/dev/null || true)"
  if [[ -z "$base_result" ]]; then base_result="$(_ab_error_case "$cid" "base case result exists" "missing" "base side did not produce this case")"; fi
  if [[ -z "$candidate_result" ]]; then candidate_result="$(_ab_error_case "$cid" "candidate case result exists" "missing" "candidate side did not produce this case")"; fi
  base_status="$(printf '%s' "$base_result" | jq -r '.status // (if .passed==true then "PASS" else "FAIL" end)')"
  candidate_status="$(printf '%s' "$candidate_result" | jq -r '.status // (if .passed==true then "PASS" else "FAIL" end)')"

  regressed=false; improved=false; delta="="
  if [[ "$base_status" == "ERROR" || "$candidate_status" == "ERROR" ]]; then
    any_error=1; delta="ERROR"
  elif [[ "$base_status" == "NEEDS_REVIEW" || "$candidate_status" == "NEEDS_REVIEW" || "$base_status" == "PENDING" || "$candidate_status" == "PENDING" ]]; then
    any_review=1; delta="NEEDS_REVIEW"
  elif [[ "$base_status" == "INDETERMINATE" || "$candidate_status" == "INDETERMINATE" || "$base_status" == "UNAVAILABLE" || "$candidate_status" == "UNAVAILABLE" ]]; then
    any_indeterminate=1; delta="INDETERMINATE"
  elif [[ "$base_status" == "PASS" && "$candidate_status" == "FAIL" ]]; then
    regressed=true; any_regression=1; regression_count=$((regression_count+1)); delta="REGRESSION"
  elif [[ "$base_status" == "FAIL" && "$candidate_status" == "PASS" ]]; then
    improved=true; improved_count=$((improved_count+1)); delta="IMPROVED"
  elif [[ "$candidate_status" == "FAIL" ]]; then
    any_candidate_fail=1; equal_count=$((equal_count+1)); delta="BOTH_FAIL"
  else
    equal_count=$((equal_count+1))
  fi

  base_passed="$(jq -n --arg s "$base_status" 'if $s=="PASS" then true elif $s=="FAIL" then false else null end')"
  candidate_passed="$(jq -n --arg s "$candidate_status" 'if $s=="PASS" then true elif $s=="FAIL" then false else null end')"
  dimension_deltas="$(jq -n --argjson b "$base_result" --argjson c "$candidate_result" '
    ($b.quality.dimensions // {}) as $bd | ($c.quality.dimensions // {}) as $cd
    | [ ((($bd|keys)+($cd|keys))|unique[]) as $k
        | ($bd[$k].score // null) as $bs | ($cd[$k].score // null) as $cs
        | {key:$k,value:{base_score:$bs,candidate_score:$cs,delta:(if ($bs|type)=="number" and ($cs|type)=="number" then ($cs-$bs) else null end),status:(if ($bs|type)=="number" and ($cs|type)=="number" then "measured" else "unavailable" end)}}
      ] | from_entries')"
  # per_case_json stores the typed comparison and resource deltas shown below.
  per_case_json="$(printf '%s' "$per_case_json" | jq --arg cid "$cid" --arg bs "$base_status" --arg cs "$candidate_status" --argjson bp "$base_passed" --argjson cp "$candidate_passed" --argjson regressed "$regressed" --argjson improved "$improved" --argjson dimensions "$dimension_deltas" --argjson b "$base_result" --argjson c "$candidate_result" --arg delta "$delta" '
    . + [{case_id:$cid,base_status:$bs,candidate_status:$cs,base_passed:$bp,candidate_passed:$cp,regressed:$regressed,improved:$improved,delta:$delta,
      models:{base:($b.env_manifest.model_id // "unknown"),candidate:($c.env_manifest.model_id // "unknown")},dimensions:$dimensions,
      resources:{base_cost_usd:($b.cost.usd // null),candidate_cost_usd:($c.cost.usd // null),cost_delta_usd:(if ($b.cost.usd|type)=="number" and ($c.cost.usd|type)=="number" then ($c.cost.usd-$b.cost.usd) else null end),
        base_tokens:($b.resources.tokens // null),candidate_tokens:($c.resources.tokens // null),base_duration_ms:($b.duration_ms // null),candidate_duration_ms:($c.duration_ms // null)}}]')"
  printf "%-40s  %-15s  %-15s  %s\n" "$cid" "$base_status" "$candidate_status" "$delta"
done <<<"$ALL_CASE_IDS"

if [[ "$(printf '%s' "$per_case_json" | jq 'length')" -eq 0 ]]; then any_error=1; fi


printf "%s\n" "--------------------------------------------------------------------"

# Summaries preserve per-dimension scores and resource availability; no global quality score.
total_cases="$(printf '%s' "$per_case_json" | jq 'length')"
error_cases="$(printf '%s' "$per_case_json" | jq '[.[] | select(.base_status=="ERROR" or .candidate_status=="ERROR")] | length')"
review_cases="$(printf '%s' "$per_case_json" | jq '[.[] | select(.base_status=="NEEDS_REVIEW" or .candidate_status=="NEEDS_REVIEW" or .base_status=="PENDING" or .candidate_status=="PENDING")] | length')"
indeterminate_cases="$(printf '%s' "$per_case_json" | jq '[.[] | select(.base_status=="INDETERMINATE" or .candidate_status=="INDETERMINATE" or .base_status=="UNAVAILABLE" or .candidate_status=="UNAVAILABLE")] | length')"
candidate_fail_cases="$(printf '%s' "$per_case_json" | jq '[.[] | select(.candidate_status=="FAIL")] | length')"
base_cost="$(jq -r '.summary.total_cost_usd // "null"' "$BASE_RESULTS")"
candidate_cost="$(jq -r '.summary.total_cost_usd // "null"' "$CAND_RESULTS")"
cost_summary="$(jq -n --argjson b "$base_cost" --argjson c "$candidate_cost" '{status:(if ($b|type)=="number" and ($c|type)=="number" then "measured" elif ($b|type)=="number" or ($c|type)=="number" then "partial" else "unavailable" end),base_usd:$b,candidate_usd:$c,delta_usd:(if ($b|type)=="number" and ($c|type)=="number" then ($c-$b) else null end),increase_pct:(if ($b|type)!="number" or ($c|type)!="number" then null elif $b==0 then (if $c==0 then 0 else null end) else (($c-$b)/$b*100) end)}')"

overall_verdict="PASS"
if [[ "$any_error" == "1" ]]; then overall_verdict="ERROR"
elif [[ "$any_review" == "1" ]]; then overall_verdict="NEEDS_REVIEW"
elif [[ "$any_indeterminate" == "1" ]]; then overall_verdict="INDETERMINATE"
elif [[ "$any_regression" == "1" ]]; then overall_verdict="REGRESSION"
elif [[ "$any_candidate_fail" == "1" ]]; then overall_verdict="FAIL"
fi

echo ""
echo "[ab] summary: total=$total_cases regressions=$regression_count improved=$improved_count equal=$equal_count verdict=$overall_verdict"
if [[ -n "$COST_WARN_PCT" ]]; then
  if [[ "$(printf '%s' "$cost_summary" | jq -r '.status')" == "measured" ]]; then
    increase_pct="$(printf '%s' "$cost_summary" | jq -r '.increase_pct')"
    if [[ "$increase_pct" == "null" ]]; then
      if [[ "$(printf '%s' "$cost_summary" | jq -r '.candidate_usd')" != "0" ]]; then echo "[ab] WARNING: cost increase is unbounded because base cost is zero" >&2; fi
    elif awk -v p="$increase_pct" -v t="$COST_WARN_PCT" 'BEGIN{exit !(p>t)}'; then
      echo "[ab] WARNING: measured cost increased $increase_pct% (threshold $COST_WARN_PCT%)" >&2
    fi
  else
    echo "[ab] cost warning threshold not evaluated: resource coverage is $(printf '%s' "$cost_summary" | jq -r '.status')" >&2
  fi
fi

jq -n \
  --arg ab_run_id "$AB_RUN_ID" --arg trigger "$TRIGGER" --arg base "$BASE" --arg candidate "$CANDIDATE" --arg verdict "$overall_verdict" \
  --arg base_model "$BASE_MODEL" --arg candidate_model "$CANDIDATE_MODEL" \
  --argjson cases "$per_case_json" --argjson total "$total_cases" --argjson regressions "$regression_count" \
  --argjson improved "$improved_count" --argjson equal "$equal_count" --argjson errors "$error_cases" \
  --argjson reviews "$review_cases" --argjson indeterminate "$indeterminate_cases" --argjson candidate_fail "$candidate_fail_cases" \
  --argjson cost "$cost_summary" \
  '{schema_version:2,ab_run_id:$ab_run_id,trigger:$trigger,base:$base,candidate:$candidate,verdict:$verdict,
    model_overrides:{base:(if $base_model=="" then null else $base_model end),candidate:(if $candidate_model=="" then null else $candidate_model end)},
    summary:{total:$total,regressions:$regressions,improved:$improved,equal:$equal,error:$errors,needs_review:$reviews,indeterminate:$indeterminate,candidate_failures:$candidate_fail,cost:$cost},
    regressions:[$cases[] | select(.regressed) | .case_id],cases:$cases}' > "$AB_DIR/results.json"
echo "[ab] machine-readable results: $AB_DIR/results.json"

case "$overall_verdict" in
  PASS) echo "[ab] OK — candidate passes all measured cases"; exit 0 ;;
  REGRESSION) echo "[ab] REGRESSION DETECTED — candidate failed after base PASS" >&2; exit 12 ;;
  ERROR) echo "[ab] ERROR — at least one side did not produce a usable case result" >&2; exit 13 ;;
  FAIL) echo "[ab] FAIL — candidate has a non-regression failing case" >&2; exit 14 ;;
  NEEDS_REVIEW) echo "[ab] NEEDS_REVIEW — human evidence is pending" >&2; exit 15 ;;
  INDETERMINATE) echo "[ab] INDETERMINATE — required evidence is unavailable" >&2; exit 16 ;;
esac

