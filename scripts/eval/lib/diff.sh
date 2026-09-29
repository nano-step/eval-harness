#!/usr/bin/env bash
# lib/diff.sh — compute 6-field FAIL diff between a fresh run and baseline.
# Settled Decision #4: 6-field schema = failed_check_id, expected, actual, diff_hint,
# transcript_span, env_delta. Settled #5: 4-class attribution from env_delta.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/attribute.sh"
source "$SCRIPT_DIR/manifest.sh"
source "$SCRIPT_DIR/pricing.sh"

  # Typed case result; keep the legacy boolean as a compatibility field.
build_case_result() {
  local case_id="$1" run_dir="$2" baseline="$3"
  local checks_file="$run_dir/checks.json" manifest_file="$run_dir/env-manifest.json"
  local transcript="$run_dir/transcript.jsonl" stability_file="$run_dir/stability.json"
  local grading_manifest_file="$run_dir/grading-manifest.json"
  local status eval_type compare_to_baseline passed baseline_passed=null
  status="$(jq -r '.status // (if .passed == true then "PASS" else "FAIL" end)' "$checks_file" 2>/dev/null || echo ERROR)"
  eval_type="$(jq -r '.evaluation_type // "regression"' "$checks_file" 2>/dev/null || echo regression)"
  compare_to_baseline="$(jq -r '.compare_to_baseline == true' "$checks_file" 2>/dev/null || echo false)"
  case "$status" in PASS|FAIL|ERROR|NEEDS_REVIEW|INDETERMINATE) ;; *) status=ERROR ;; esac
  [[ "$status" == "PASS" ]] && passed=true || passed=false

  local env_delta='{"keys_changed":["__no_baseline__"],"details":{}}'
  if [[ "$compare_to_baseline" == "true" && -f "$baseline" ]]; then
    if declare -F verify_baseline_integrity >/dev/null && ! verify_baseline_integrity "$baseline"; then
      echo "[eval-harness] WARNING: baseline integrity check FAILED for $baseline (checks_checksum mismatch — possible tampering)" >&2
    fi
    baseline_passed="$(jq -r 'if .passed == true then true elif .passed == false then false else null end' "$baseline" 2>/dev/null || echo null)"
    local baseline_manifest_tmp; baseline_manifest_tmp="$(mktemp)"
    jq '.env_manifest // {}' "$baseline" > "$baseline_manifest_tmp"
    env_delta="$(diff_manifests "$baseline_manifest_tmp" "$manifest_file")"
    rm -f "$baseline_manifest_tmp"
  fi

  local attribution='{"top":"NOT_COMPARED","also_observed":[],"evidence":{}}'
  if [[ "$status" == "FAIL" && "$compare_to_baseline" == "true" ]]; then attribution="$(attribute "$env_delta")"; fi
  local rerun_cmd="bash scripts/eval/run.sh --case=$case_id --skill=\${SKILL_UNDER_TEST} --debug --pin-env=baseline"
  local model_id; model_id="$(jq -r '.model_id // "unknown"' "$manifest_file" 2>/dev/null || echo unknown)"
  local tokens; tokens="$(tokens_from_transcript "$transcript")"
  local input_tokens="${tokens% *}" output_tokens="${tokens#* }" usage_available=false cost_json
  if [[ -s "$transcript" ]] && jq -se '[.[] | .. | objects | .usage? | objects | select((has("input_tokens") or has("prompt_tokens")) and (has("output_tokens") or has("completion_tokens")))] | length > 0' "$transcript" >/dev/null 2>&1; then usage_available=true; fi
  if [[ "$usage_available" == "true" ]]; then
    cost_json="$(compute_cost_usd "$model_id" "${input_tokens:-0}" "${output_tokens:-0}" | jq '. + {status:(if .usd == null then "unavailable" else "measured" end)}')"
  else
    cost_json='{"status":"unavailable","usd":null,"reason":"transcript usage metadata unavailable"}'
  fi

  local stability_json='{"samples":1,"byte_identical":true,"hashes":[],"performed":false}'
  if [[ -f "$stability_file" ]]; then stability_json="$(cat "$stability_file")"; fi
  if [[ "$status" == "FAIL" ]]; then
    local is_flaky; is_flaky="$(printf '%s' "$stability_json" | jq -r 'if .performed and (.byte_identical | not) then "true" else "false" end')"
    if [[ "$is_flaky" == "true" ]]; then
      attribution="$(printf '%s' "$attribution" | jq --argjson stability "$stability_json" 'if .top == "UNKNOWN_DRIFT" then .top="NON_DETERMINISTIC_DRIFT" else . end | .also_observed += ["NON_DETERMINISTIC_DRIFT"] | .also_observed |= unique | .evidence.stability=$stability')"
    fi
  fi

  local manifest_sha="" grading_manifest_path=""
  if [[ -f "$grading_manifest_file" ]]; then
    manifest_sha="$(portable_sha256_file "$grading_manifest_file" | cut -d' ' -f1)"
    grading_manifest_path="$(basename "$run_dir")/grading-manifest.json"
  fi
  jq -n \
    --arg case_id "$case_id" --arg status "$status" --arg evaluation_type "$eval_type" \
    --argjson passed "$passed" --argjson compare_to_baseline "$compare_to_baseline" --argjson baseline_passed "$baseline_passed" \
    --slurpfile checks "$checks_file" --argjson env_delta "$env_delta" --argjson attribution "$attribution" \
    --slurpfile manifest "$manifest_file" --arg rerun "$rerun_cmd" --argjson cost "$cost_json" \
    --argjson stability "$stability_json" --argjson usage_available "$usage_available" \
    --arg input_tokens "$input_tokens" --arg output_tokens "$output_tokens" \
    --arg grading_path "$grading_manifest_path" --arg grading_sha "$manifest_sha" \
    '{case_id:$case_id,passed:$passed,status:$status,evaluation_type:$evaluation_type,
      compare_to_baseline:$compare_to_baseline,baseline_passed:$baseline_passed,
      regression:($compare_to_baseline and $baseline_passed==true and $status=="FAIL"),
      checks:($checks[0].checks // []),stochastic:($checks[0].stochastic // null),
      quality:($checks[0].quality // {dimensions:{},aggregate:null}),
      reliability:($checks[0].reliability // null),env_delta:$env_delta,attribution:$attribution,
      stability:$stability,env_manifest:($manifest[0] // {}),cost:$cost,
      resources:{tokens:{status:(if $usage_available then "measured" else "unavailable" end),
        input_tokens:(if $usage_available then ($input_tokens|tonumber) else null end),
        output_tokens:(if $usage_available then ($output_tokens|tonumber) else null end)},cost:$cost},
      grading_manifest:(if $grading_path=="" then null else {path:$grading_path,sha256:$grading_sha} end),rerun:$rerun}'
}


# Usage: build_run_summary <results_array_json> <run_id> <trigger> [max_regressions]
# Aggregates typed outcomes without folding product dimensions into a global score.
build_run_summary() {
  local results_json="$1" run_id="$2" trigger="$3" max_regressions="${4:--1}"
  local total pass fail errors needs_review indeterminate regressions regression_count
  total="$(printf '%s' "$results_json" | jq 'length')"
  pass="$(printf '%s' "$results_json" | jq '[.[] | select(.status=="PASS" or (.status==null and .passed==true))] | length')"
  fail="$(printf '%s' "$results_json" | jq '[.[] | select(.status=="FAIL" or (.status==null and .passed==false))] | length')"
  errors="$(printf '%s' "$results_json" | jq '[.[] | select(.status=="ERROR")] | length')"
  if [[ "$total" -eq 0 ]]; then errors=1; fi
  needs_review="$(printf '%s' "$results_json" | jq '[.[] | select(.status=="NEEDS_REVIEW")] | length')"
  indeterminate="$(printf '%s' "$results_json" | jq '[.[] | select(.status=="INDETERMINATE")] | length')"
  regressions="$(printf '%s' "$results_json" | jq '[.[] | select(.regression==true or (.regression==null and .baseline_passed==true and .status=="FAIL")) | .case_id]')"
  regression_count="$(printf '%s' "$regressions" | jq 'length')"
  local threshold_exceeded=false
  if [[ "$max_regressions" =~ ^[0-9]+$ ]] && [[ "$regression_count" -gt "$max_regressions" ]]; then threshold_exceeded=true; fi

  local verdict="PASS"
  if [[ "$errors" -gt 0 ]]; then verdict="ERROR"
  elif [[ "$regression_count" -gt 0 ]]; then verdict="REGRESSION"
  elif [[ "$fail" -gt 0 ]]; then verdict="FAIL"
  elif [[ "$needs_review" -gt 0 ]]; then verdict="NEEDS_REVIEW"
  elif [[ "$indeterminate" -gt 0 ]]; then verdict="INDETERMINATE"
  fi

  local total_cost_usd token_metrics duration_metrics cost_metrics
  cost_metrics="$(printf '%s' "$results_json" | jq '. as $cases | [.[].cost.usd | select(type=="number")] as $c | {status:(if ($c|length)==0 then "unavailable" elif ($c|length)==($cases|length) then "measured" else "partial" end),measured_cases:($c|length),total_cases:($cases|length),measured_subtotal_usd:(if ($c|length)==0 then null else ($c|add) end),total_usd:(if ($c|length)==($cases|length) and ($c|length)>0 then ($c|add) else null end)}')"
  total_cost_usd="$(printf '%s' "$cost_metrics" | jq -c '.total_usd')"
  token_metrics="$(printf '%s' "$results_json" | jq '
    [.[].resources.tokens? | select(.status=="measured")] as $t
    | {status:(if ($t|length)==0 then "unavailable" elif ($t|length)==(length) then "measured" else "partial" end),
       measured_cases:($t|length),input_tokens:(if ($t|length)==0 then null else ([$t[].input_tokens|select(type=="number")] | if length==0 then null else add end) end),
       output_tokens:(if ($t|length)==0 then null else ([$t[].output_tokens|select(type=="number")] | if length==0 then null else add end) end)}')"
  duration_metrics="$(printf '%s' "$results_json" | jq '
    [.[].duration_ms | select(type=="number")] as $d
    | {status:(if ($d|length)==0 then "unavailable" elif ($d|length)==(length) then "measured" else "partial" end),
       measured_cases:($d|length),total_ms:(if ($d|length)==0 then null else ($d|add) end)}')"

  jq -n \
    --arg run_id "$run_id" --arg trigger "$trigger" --arg verdict "$verdict" \
    --argjson total "$total" --argjson pass "$pass" --argjson fail "$fail" \
    --argjson errors "$errors" --argjson needs_review "$needs_review" --argjson indeterminate "$indeterminate" \
    --argjson regressions "$regressions" --argjson cases "$results_json" --argjson cost_usd "$total_cost_usd" \
    --argjson cost_metrics "$cost_metrics" --argjson tokens "$token_metrics" --argjson duration "$duration_metrics" \
    --arg max_regressions "$max_regressions" --argjson threshold_exceeded "$threshold_exceeded" \
    '{schema_version:3,run_id:$run_id,trigger:$trigger,verdict:$verdict,
      summary:{total:$total,pass:$pass,fail:$fail,error:$errors,needs_review:$needs_review,indeterminate:$indeterminate,
        regression_count:($regressions|length),total_cost_usd:$cost_usd,
        resources:{cost:$cost_metrics,tokens:$tokens,duration:$duration}},
      gate:{max_regressions:(if ($max_regressions|test("^[0-9]+$")) then ($max_regressions|tonumber) else null end),
        regression_threshold_exceeded:$threshold_exceeded},
      regressions:$regressions,cases:$cases}'
}


# Usage: render_diff_md <results_json_path> <out_md_path>
# Writes a human-readable markdown summary per Settled Decision #15.
render_diff_md() {
  local results="$1"
  local out="$2"

  local verdict; verdict="$(jq -r '.verdict' "$results")"
  local run_id; run_id="$(jq -r '.run_id' "$results")"
  local trigger; trigger="$(jq -r '.trigger' "$results")"

  {
    echo "# eval-harness run $run_id"
    echo
    echo "- trigger: \`$trigger\`"
    echo "- verdict: **$verdict**"
    echo
    local regressions; regressions="$(jq -r '.regressions | length' "$results")"
    if [[ "$regressions" -gt 0 ]]; then
      echo "## REGRESSION ($regressions)"
      echo
      jq -r '.cases[] | select(.baseline_passed == true and .passed == false) |
        "### " + .case_id + "\n" +
        "- attribution: **" + .attribution.top + "**" +
          (if (.attribution.also_observed | length) > 0
           then " (also: " + (.attribution.also_observed | join(", ")) + ")"
           else "" end) + "\n" +
        "- env_delta keys: " + (.env_delta.keys_changed | join(", ")) + "\n" +
        "- failed checks: " + ([.checks[] | select(.passed | not) | .failed_check_id] | join("; ")) + "\n" +
        "\n#### Rerun in isolation\n" +
        "```\n" + .rerun + "\n```\n"
      ' "$results"
    fi

    local fails; fails="$(jq -r '[.cases[] | select(.passed == false)] | length' "$results")"
    if [[ "$fails" -gt 0 ]]; then
      echo "## FAILED CHECKS (full detail)"
      echo
      jq -r '.cases[] | select(.passed == false) |
        "### " + .case_id + "\n" +
        ([.checks[] | select(.passed | not) |
          "- **" + .failed_check_id + "**\n" +
          "  - expected: `" + (.expected | tostring) + "`\n" +
          "  - actual:   `" + (.actual | tostring) + "`\n" +
          "  - hint:     " + (.diff_hint // "") +
          (if .fix_proposal != null then
            "\n  - **fix_proposal** (" + .fix_proposal.kind + ", confidence: " + .fix_proposal.confidence + "):\n" +
            "    - " + .fix_proposal.instruction + "\n" +
            "    - patch snippet: `" + (.fix_proposal.patch_snippet | tostring) + "`"
           else "" end)
        ] | join("\n")) + "\n"
      ' "$results"
    fi

    local stable; stable="$(jq -r '[.cases[] | select(.passed == true)] | length' "$results")"
    if [[ "$stable" -gt 0 ]]; then
      echo "## STABLE"
      echo
      jq -r '.cases[] | select(.passed == true) | "- " + .case_id + ": PASS"' "$results"
    fi
  } > "$out"
}

export -f build_case_result build_run_summary render_diff_md

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-}" in
    case)    shift; build_case_result "$@" ;;
    summary) shift; build_run_summary "$@" ;;
    md)      shift; render_diff_md "$@" ;;
    *) echo "usage: diff.sh {case <id> <run_dir> <baseline> | summary <results_json> <run_id> <trigger> | md <results.json> <out.md>}" >&2; exit 2 ;;
  esac
fi
