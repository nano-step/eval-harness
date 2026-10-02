#!/usr/bin/env bash
# lib/score.sh — run all checks against a case's transcript + working directory.
# Settled Decision #18: run ALL checks per case (no first-fail-exit), aggregate all failures.

set -euo pipefail

_SCORE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./yq-shim.sh
source "$_SCORE_LIB_DIR/yq-shim.sh"
source "$_SCORE_LIB_DIR/llm_judge.sh"
source "$_SCORE_LIB_DIR/autofix.sh"
source "$_SCORE_LIB_DIR/extended_graders.sh"

# Usage: run_check <check_yaml_path> <workdir> <transcript_jsonl>
# Returns a single check-result JSON to stdout. Exit 0 always; pass/fail in JSON.
run_check() {
  local check_file="$1"
  local workdir="$2"
  local transcript="$3"

  local kind
  kind="$(yq -r '.kind' "$check_file" 2>/dev/null || echo unknown)"
  local transcript_unavailable; transcript_unavailable="$(printenv EVAL_TRANSCRIPT_UNAVAILABLE 2>/dev/null || echo 0)"

  local unavailable_reason=""
  if [[ "$transcript_unavailable" == "1" ]]; then
    case "$kind" in
      output_contains|output_not_contains) unavailable_reason="required transcript evidence unavailable" ;;
      llm_judge)
        local judge_target judge_target_path
        judge_target="$(yq -r '.target_file // ""' "$check_file" 2>/dev/null || echo "")"
        judge_target_path=""
        [[ -z "$judge_target" ]] || judge_target_path="$(_score_resolve_workdir_file "$workdir" "$judge_target" 2>/dev/null || true)"
        if [[ -z "$judge_target_path" || ! -f "$judge_target_path" ]]; then unavailable_reason="transcript and target artifact evidence unavailable"; fi ;;
    esac
  fi
  if [[ -n "$unavailable_reason" ]]; then
    result="$(jq -n --arg kind "$kind" --arg reason "$unavailable_reason" '{kind:$kind,passed:false,status:"UNAVAILABLE",score:null,failed_check_id:("unavailable:"+$kind),expected:"required evidence",actual:$reason,diff_hint:$reason}')"
    decorate_check_result "$check_file" "$result"
    return 0
  fi

  local result
  case "$kind" in
    shell)
      result="$(score_shell "$check_file" "$workdir")" ;;
    jq_path_contains)
      result="$(score_jq_path_contains "$check_file" "$workdir")" ;;
    file_exists)
      result="$(score_file_exists "$check_file" "$workdir")" ;;
    output_contains)
      result="$(score_output_contains "$check_file" "$transcript")" ;;
    output_not_contains)
      result="$(score_output_not_contains "$check_file" "$transcript")" ;;
    llm_judge)
      result="$(score_llm_judge "$check_file" "$workdir" "$transcript")" ;;
    metric_score)
      result="$(score_metric_score "$check_file" "$workdir")" ;;
    trajectory)
      result="$(score_trajectory "$check_file" "$workdir")" ;;
    human_review)
      result="$(score_human_review "$check_file" "$workdir")" ;;
    *)
      result="$(jq -n --arg kind "$kind" '{
        kind: $kind,
        passed: false,
        failed_check_id: ("unknown_kind:" + $kind),
        expected: "known check kind",
        actual: $kind,
        diff_hint: "check kind not implemented",
        error: true
      }')" ;;
  esac
  decorate_check_result "$check_file" "$result"
}


score_shell_exact_lines() {
  local out="$1"
  local expected_json="$2"

  jq -e -n \
    --arg out "$out" \
    --argjson expected "$expected_json" \
    '
      def drop_trailing_empty:
        if length > 0 and .[-1] == "" then
          .[0:-1] | drop_trailing_empty
        else
          .
        end;

      ($out
        | split("\n")
        | map(sub("[ \\t\\r]+$"; ""))
        | drop_trailing_empty) == $expected
    ' >/dev/null
}

score_shell() {
  local check_file="$1"; local workdir="$2"
  local cmd; cmd="$(yq -r '.cmd' "$check_file")"
  local expect_regex; expect_regex="$(yq -r '.expect_regex // empty' "$check_file")"
  local expect_min; expect_min="$(yq -r '.expect_min // empty' "$check_file")"
  local expect_exact; expect_exact="$(yq -r '.expect_exact // empty' "$check_file")"
  local expect_exact_lines; expect_exact_lines="$(yq -o=json '.expect_exact_lines // []' "$check_file")"
  local has_expect_exact_lines; has_expect_exact_lines="$(yq -o=json '.' "$check_file" | jq 'has("expect_exact_lines")')"
  local unsafe_opt_in; unsafe_opt_in="$(yq -r '.unsafe_shell // false' "$check_file" 2>/dev/null || echo false)"

  # (#8) A typo like `expected_regex:` (vs `expect_regex:`) leaves every expect_* absent,
  # which would otherwise silently FAIL with "expected (no expectation)". Treat a check
  # with NO expect_* field present as a harness error so the misconfig is visible.
  # Presence (not emptiness) is what matters: `expect_exact: ""` is a valid expectation
  # (expect empty output), so we use a sentinel default to tell "absent" from "empty".
  local check_json has_regex has_min has_exact
  check_json="$(yq -o=json '.' "$check_file" 2>/dev/null || echo '{}')"
  has_regex="$(printf '%s' "$check_json" | jq -r 'has("expect_regex")')"
  has_min="$(printf '%s' "$check_json" | jq -r 'has("expect_min")')"
  has_exact="$(printf '%s' "$check_json" | jq -r 'has("expect_exact")')"
  if [[ "$has_regex" == "false" && "$has_min" == "false" && "$has_exact" == "false" && "$has_expect_exact_lines" == "false" ]]; then
    jq -n --arg cmd "$cmd" '{
      kind: "shell",
      passed: false,
      failed_check_id: ("shell:" + $cmd),
      expected: "at least one expect_* field (expect_regex / expect_min / expect_exact / expect_exact_lines)",
      actual: "none set — check YAML for a typo like '\''expected_*'\''",
      diff_hint: "this check is misconfigured; treating as harness error",
      error: true
    }'
    return 0
  fi

  local out safe_result
  if [[ "$unsafe_opt_in" == "true" || "${EVAL_ALLOW_UNSAFE_SHELL:-0}" == "1" ]]; then
    out="$(cd "$workdir" && bash -c "$cmd" 2>&1 || true)"
  else
    safe_result="$(python3 "$_SCORE_LIB_DIR/safe_shell.py" "$workdir" "$cmd" 2>/dev/null || echo '{}')"
    if [[ "$(printf '%s' "$safe_result" | jq -r '.safe // false')" != "true" ]]; then
      jq -n --arg cmd "$cmd" --arg reason "$(printf '%s' "$safe_result" | jq -r '.error // "unsupported command"')" '{kind:"shell",passed:false,failed_check_id:("shell:"+$cmd),expected:"supported non-shell command expression",actual:"rejected by constrained runner",diff_hint:($reason+". Only jq, printf, and terminal wc -l are supported without unsafe_shell: true; this runner is not an OS sandbox."),error:true}'
      return 0
    fi
    out="$(printf '%s' "$safe_result" | jq -r '.output')"
  fi

  local passed="false"
  local diff_hint=""
  if [[ -n "$expect_regex" ]] && echo "$out" | grep -Eq -- "$expect_regex"; then
    passed="true"
  elif [[ -n "$expect_min" ]]; then
    local n; n="$(echo "$out" | tr -d ' \n')"
    if [[ "$n" =~ ^[0-9]+$ ]] && [[ "$n" -ge "$expect_min" ]]; then
      passed="true"
    else
      diff_hint="got=$out, expect_min=$expect_min"
    fi
  elif [[ "$has_exact" == "true" ]] && [[ "$(echo "$out" | tr -d '\n')" == "$expect_exact" ]]; then
    # Present (even if empty: expect_exact:"" means "expect empty output"). #8 distinguishes
    # a present-but-empty expectation from an absent one via $has_exact.
    passed="true"
  elif [[ "$has_expect_exact_lines" == "true" ]]; then
    if score_shell_exact_lines "$out" "$expect_exact_lines"; then
      passed="true"
    else
      diff_hint="output lines did not match expect_exact_lines after trailing whitespace normalization"
    fi
  fi

  jq -n \
    --arg kind shell \
    --arg cmd "$cmd" \
    --arg out "$out" \
    --arg expect_regex "$expect_regex" \
    --arg expect_min "$expect_min" \
    --arg expect_exact "$expect_exact" \
    --argjson exact_present "$has_exact" \
    --argjson has_expect_exact_lines "$has_expect_exact_lines" \
    --argjson expect_exact_lines "$expect_exact_lines" \
    --argjson passed "$passed" \
    --arg diff_hint "$diff_hint" \
    '{
      kind: $kind,
      passed: $passed,
      failed_check_id: ("shell:" + $cmd),
      expected: (
        if $expect_regex != "" then $expect_regex
        elif $expect_min != "" then ("min " + $expect_min)
        elif $expect_exact != "" then $expect_exact
        elif $has_expect_exact_lines then $expect_exact_lines
        else "(no expectation)"
        end),
      actual: $out,
      diff_hint: $diff_hint
    }'
}

score_jq_path_contains() {
  local check_file="$1"; local workdir="$2"
  local target_file; target_file="$(yq -r '.file' "$check_file")"
  local path; path="$(yq -r '.path' "$check_file")"
  path="$(_score_normalize_jq_path "$path")"
  local contains_json; contains_json="$(yq -o=json '.contains' "$check_file")"

  local target; target="$(_score_resolve_workdir_file "$workdir" "$target_file" 2>/dev/null || true)"
  if [[ -z "$target" ]]; then
    _score_check_error jq_path_contains "$target_file:$path" "safe relative path" "$target_file" "JSON artifact path escapes the workdir"
    return 0
  fi
  if [[ ! -f "$target" ]]; then
    jq -n --arg kind jq_path_contains --arg path "$path" --arg file "$target_file" '{
      kind: $kind,
      passed: false,
      failed_check_id: ("jq_path_contains:" + $file + ":" + $path),
      expected: "file exists",
      actual: "file missing",
      diff_hint: ("file not found: " + $file)
    }'
    return 0
  fi

  local actual_arr; actual_arr="$(jq -c "$path" "$target" 2>/dev/null || echo 'null')"
  local missing
  missing="$(jq -n --argjson required "$contains_json" --argjson actual "$actual_arr" \
    '($required - ($actual // []))')"

  local missing_count; missing_count="$(echo "$missing" | jq 'length')"
  local passed
  if [[ "$missing_count" -eq 0 ]]; then passed=true; else passed=false; fi

  jq -n \
    --arg kind jq_path_contains \
    --arg path "$path" \
    --arg file "$target_file" \
    --argjson required "$contains_json" \
    --argjson actual "$actual_arr" \
    --argjson missing "$missing" \
    --argjson passed "$passed" \
    '{
      kind: $kind,
      passed: $passed,
      failed_check_id: ("jq_path_contains:" + $file + ":" + $path),
      expected: $required,
      actual: $actual,
      diff_hint: ("missing from " + $path + ": " + ($missing | tostring))
    }'
}

score_file_exists() {
  local check_file="$1"; local workdir="$2"
  local target; target="$(yq -r '.path' "$check_file")"
  local full; full="$(_score_resolve_workdir_file "$workdir" "$target" 2>/dev/null || true)"
  if [[ -z "$full" ]]; then
    _score_check_error file_exists "$target" "safe relative path" "$target" "file path escapes the workdir"
    return 0
  fi
  local passed=false
  [[ -f "$full" ]] && passed=true
  jq -n --arg target "$target" --argjson passed "$passed" '{
    kind: "file_exists",
    passed: $passed,
    failed_check_id: ("file_exists:" + $target),
    expected: "file present",
    actual: (if $passed then "present" else "missing" end),
    diff_hint: (if $passed then "" else ("expected file at " + $target) end)
  }'
}

score_output_contains() {
  local check_file="$1"; local transcript="$2"
  local needle; needle="$(yq -r '.value' "$check_file")"

  local passed=false
  local line_no=""
  local end_line=""
  if [[ -f "$transcript" ]]; then
    local match
    match="$(grep -n -F -- "$needle" "$transcript" | head -1 || true)"
    if [[ -n "$match" ]]; then
      passed=true
      line_no="${match%%:*}"
      end_line="$line_no"
    fi
  fi

  jq -n \
    --arg needle "$needle" \
    --argjson passed "$passed" \
    --arg transcript "$transcript" \
    --arg start_line "$line_no" \
    --arg end_line "$end_line" \
    '{
      kind: "output_contains",
      passed: $passed,
      failed_check_id: ("output_contains:" + $needle),
      expected: $needle,
      actual: (if $passed then "present" else "absent" end),
      diff_hint: (if $passed then "" else ("transcript does not contain: " + $needle) end),
      transcript_span: (if $passed and $start_line != "" then
        {start_line: ($start_line | tonumber), end_line: ($end_line | tonumber), transcript_path: $transcript}
       else null end)
    }'
}

score_llm_judge() {
  local check_file="$1"; local workdir="$2"; local transcript="$3"
  local rubric; rubric="$(yq -r '.rubric' "$check_file")"
  local target_file; target_file="$(yq -r '.target_file // ""' "$check_file")"
  local samples; samples="$(yq -r '.samples // 3' "$check_file")"
  local judge_model
  judge_model="$(yq -r '.judge_model // ""' "$check_file")"
  [[ -z "$judge_model" ]] && judge_model="${EVAL_LLM_JUDGE_MODEL:-anthropic/claude-sonnet-4-6}"

  local target_path=""
  if [[ -n "$target_file" ]]; then
    target_path="$(_score_resolve_workdir_file "$workdir" "$target_file" 2>/dev/null || true)"
    if [[ -z "$target_path" ]]; then
      _score_check_error llm_judge "$target_file" "safe relative path" "$target_file" "judge artifact path escapes the workdir"
      return 0
    fi
  fi
  local artifact_content=""
  if [[ -n "$target_path" && -f "$target_path" ]]; then
    artifact_content="$(head -c 8000 "$target_path")"
  elif [[ -f "$transcript" ]]; then
    artifact_content="$(head -c 8000 "$transcript")"
  fi

  local system_prompt; system_prompt="$(judge_system_prompt)"
  local user_prompt
  user_prompt="$(printf 'RUBRIC:\n%s\n\nARTIFACT:\n%s' "$rubric" "$artifact_content")"

  local judge_result
  judge_result="$(llm_judge_majority "$judge_model" "$system_prompt" "$user_prompt" "$samples")"

  local verdict
  verdict="$(echo "$judge_result" | jq -r '.majority_verdict // "null"')"
  local passed=false
  if [[ "$verdict" == "PASS" ]]; then passed=true; fi

  jq -n \
    --argjson passed "$passed" \
    --arg verdict "$verdict" \
    --arg rubric "$rubric" \
    --argjson judge "$judge_result" \
    '{
      kind: "llm_judge",
      passed: $passed,
      failed_check_id: ("llm_judge:" + ($rubric | .[0:60])),
      expected: "PASS verdict (majority)",
      actual: $verdict,
      diff_hint: ($judge.reason // ""),
      judge: $judge
    }'
}

score_output_not_contains() {
  local check_file="$1"; local transcript="$2"
  local needle; needle="$(yq -r '.value' "$check_file")"

  if [[ ! -f "$transcript" ]] || [[ ! -s "$transcript" ]]; then
    local reason="transcript missing"
    [[ -f "$transcript" ]] && reason="transcript empty (0 bytes)"
    jq -n --arg needle "$needle" --arg reason "$reason" --arg t "$transcript" '{
      kind: "output_not_contains",
      passed: false,
      failed_check_id: ("output_not_contains:" + $needle),
      expected: ("absence of " + $needle),
      actual: $reason,
      diff_hint: ("cannot verify absence — " + $reason + " at " + $t + ". This usually means opencode failed to start, crashed, or was killed by timeout. Re-run with --debug to inspect."),
      error: true,
      transcript_span: null
    }'
    return 0
  fi

  local passed=true
  local line_no=""
  local match
  match="$(grep -n -F -- "$needle" "$transcript" | head -1 || true)"
  if [[ -n "$match" ]]; then
    passed=false
    line_no="${match%%:*}"
  fi

  jq -n \
    --arg needle "$needle" \
    --argjson passed "$passed" \
    --arg transcript "$transcript" \
    --arg start_line "$line_no" \
    '{
      kind: "output_not_contains",
      passed: $passed,
      failed_check_id: ("output_not_contains:" + $needle),
      expected: ("absence of " + $needle),
      actual: (if $passed then "absent" else "present" end),
      diff_hint: (if $passed then "" else ("transcript contains forbidden: " + $needle) end),
      transcript_span: (if $passed then null else
        {start_line: ($start_line | tonumber), end_line: ($start_line | tonumber), transcript_path: $transcript}
       end)
    }'
}

# Usage: run_all_checks <case_yaml> <workdir> <transcript_jsonl> <out_json>
# Required graders retain legacy all-pass semantics; optional checks report but do not gate.
run_all_checks() {
  local case_file="$1"; local workdir="$2"; local transcript="$3"; local out="$4"
  local checks_json n_checks required_count
  checks_json="$(yq -o=json '.checks // []' "$case_file" 2>/dev/null || echo null)"
  n_checks="$(printf '%s' "$checks_json" | jq -r 'if type=="array" then length else -1 end')"
  required_count="$(printf '%s' "$checks_json" | jq -r 'if type=="array" then [.[] | select(.required != false)] | length else 0 end')"
  local eval_type compare_to_baseline
  eval_type="$(yq -r '.eval_type // "regression"' "$case_file" 2>/dev/null || echo regression)"
  compare_to_baseline="$(yq -r '.compare_to_baseline // false' "$case_file" 2>/dev/null || echo false)"
  if [[ "$eval_type" != "capability" && "$eval_type" != "regression" && "$eval_type" != "product" ]]; then
    jq -n --arg type "$eval_type" --arg cid "$(yq -r '.id // "unknown"' "$case_file")" '{
      passed:false,status:"ERROR",evaluation_type:$type,compare_to_baseline:false,
      total:0,pass_count:0,fail_count:1,needs_review:false,indeterminate:false,
      checks:[{kind:"harness_error",passed:false,status:"ERROR",error:true,
        failed_check_id:("eval_type:"+$cid),expected:"capability|regression|product",actual:$type,
        diff_hint:"unsupported eval_type"}],quality:{dimensions:{},aggregate:null}
    }' > "$out"
    return 0
  fi
  if [[ "$compare_to_baseline" != "true" && "$compare_to_baseline" != "false" ]]; then
    jq -n --arg type "$eval_type" --arg cid "$(yq -r '.id // "unknown"' "$case_file")" --arg actual "$compare_to_baseline" '{passed:false,status:"ERROR",evaluation_type:$type,compare_to_baseline:false,total:0,pass_count:0,fail_count:1,needs_review:false,indeterminate:false,checks:[{kind:"harness_error",passed:false,status:"ERROR",error:true,failed_check_id:("baseline_comparison:"+$cid),expected:"boolean compare_to_baseline",actual:$actual,diff_hint:"invalid baseline comparison setting"}],quality:{dimensions:{},aggregate:null}}' > "$out"
    return 0
  fi
  if ! [[ "$n_checks" =~ ^[1-9][0-9]*$ ]] || [[ "$required_count" -eq 0 ]]; then
    jq -n --arg type "$eval_type" --arg cid "$(yq -r '.id // "unknown"' "$case_file")" --arg actual "checks=$n_checks required=$required_count" '{passed:false,status:"ERROR",evaluation_type:$type,compare_to_baseline:false,total:0,pass_count:0,fail_count:1,needs_review:false,indeterminate:false,checks:[{kind:"harness_error",passed:false,status:"ERROR",error:true,failed_check_id:("empty_or_invalid_checks:"+$cid),expected:"one or more valid checks including at least one required grader",actual:$actual,diff_hint:"case has no usable required evaluation gate"}],quality:{dimensions:{},aggregate:null}}' > "$out"
    return 0
  fi
  if [[ "$eval_type" == "regression" ]]; then compare_to_baseline=true; fi

  if [[ "$compare_to_baseline" != "true" && "$compare_to_baseline" != "false" ]]; then compare_to_baseline=false; fi

  local results_json="[]"
  local autofix_setting
  autofix_setting="$(printenv EVAL_AUTOFIX 2>/dev/null || echo 1)"
  local i=0
  while [[ $i -lt $n_checks ]]; do
    local tmp; tmp="$(mktemp)"
    yq -o=yaml ".checks[$i]" "$case_file" > "$tmp"
    local res; res="$(run_check "$tmp" "$workdir" "$transcript")"
    if [[ "$autofix_setting" == "1" ]]; then res="$(propose_fix "$res")"; fi
    results_json="$(jq -n --argjson results "$results_json" --argjson result "$res" '$results + [$result]')"
    rm -f "$tmp"
    i=$((i+1))
  done
  local status_json
  status_json="$(printf '%s' "$results_json" | jq -r '
    map(select(.required != false)) as $required
    | if ($required|length)==0 then "ERROR"
      elif any($required[]; .status == "ERROR") then "ERROR"
      elif any($required[]; .status == "FAIL") then "FAIL"
      elif any($required[]; .status == "PENDING") then "NEEDS_REVIEW"
      elif any($required[]; .status == "UNAVAILABLE" or .status == "ABSTAIN") then "INDETERMINATE"
      else "PASS" end')"
  local quality_json
  quality_json="$(printf '%s' "$results_json" | jq '
    [ .[] | select(.dimension != null) ]
    | group_by(.dimension)
    | map(.[0].dimension as $dimension
      | {key:$dimension, value:(
          if any(.[]; (.score|type) != "number") then
            {score:null,status:"unavailable",check_ids:map(.failed_check_id)}
          else
            ((map(.score * .weight) | add) / (map(.weight) | add)) as $score
            | {score:$score,status:"measured",check_ids:map(.failed_check_id)}
          end
        )})
    | from_entries')"
  jq -n \
    --argjson results "$results_json" \
    --argjson quality "$quality_json" \
    --arg status "$status_json" \
    --arg eval_type "$eval_type" \
    --argjson compare_to_baseline "$compare_to_baseline" \
    --arg total "$n_checks" \
    '{
      passed:($status=="PASS"),status:$status,evaluation_type:$eval_type,
      compare_to_baseline:$compare_to_baseline,
      needs_review:($status=="NEEDS_REVIEW"),indeterminate:($status=="INDETERMINATE"),
      total:($total|tonumber),
      pass_count:($results|map(select(.status=="PASS" or (.status==null and .passed==true)))|length),
      fail_count:($results|map(select(.status=="FAIL" or (.status==null and .passed==false)))|length),
      error_count:($results|map(select(.status=="ERROR"))|length),
      needs_review_count:($results|map(select(.status=="PENDING"))|length),
      unavailable_count:($results|map(select(.status=="UNAVAILABLE" or .status=="ABSTAIN"))|length),
      checks:$results,quality:{dimensions:$quality,aggregate:null,
        aggregation:"per-dimension weighted mean; no global score"}
    }' > "$out"
}

export -f run_check run_all_checks score_shell score_jq_path_contains score_file_exists score_output_contains score_output_not_contains score_metric_score score_trajectory score_human_review decorate_check_result

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-}" in
    check) shift; run_check "$@" ;;
    all)   shift; run_all_checks "$@" ;;
    *) echo "usage: score.sh {check <check.yaml> <workdir> <transcript> | all <case.yaml> <workdir> <transcript> <out>}" >&2; exit 2 ;;
  esac
fi
