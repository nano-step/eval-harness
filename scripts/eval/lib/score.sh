#!/usr/bin/env bash
# lib/score.sh — run all checks against a case's transcript + working directory.
# Settled Decision #18: run ALL checks per case (no first-fail-exit), aggregate all failures.

set -euo pipefail

_SCORE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./yq-shim.sh
source "$_SCORE_LIB_DIR/yq-shim.sh"
source "$_SCORE_LIB_DIR/llm_judge.sh"
source "$_SCORE_LIB_DIR/autofix.sh"

# Usage: run_check <check_yaml_path> <workdir> <transcript_jsonl>
# Returns a single check-result JSON to stdout. Exit 0 always; pass/fail in JSON.
run_check() {
  local check_file="$1"
  local workdir="$2"
  local transcript="$3"

  local kind
  kind="$(yq -r '.kind' "$check_file" 2>/dev/null || echo unknown)"

  case "$kind" in
    shell)
      score_shell "$check_file" "$workdir"
      ;;
    jq_path_contains)
      score_jq_path_contains "$check_file" "$workdir"
      ;;
    file_exists)
      score_file_exists "$check_file" "$workdir"
      ;;
    output_contains)
      score_output_contains "$check_file" "$transcript"
      ;;
    output_not_contains)
      score_output_not_contains "$check_file" "$transcript"
      ;;
    llm_judge)
      score_llm_judge "$check_file" "$workdir" "$transcript"
      ;;
    *)
      jq -n --arg kind "$kind" '{
        kind: $kind,
        passed: false,
        failed_check_id: ("unknown_kind:" + $kind),
        expected: "known check kind",
        actual: $kind,
        diff_hint: "check kind not implemented in v0.1.0",
        error: true
      }'
      ;;
  esac
}

score_shell_is_unsafe() {
  local cmd="$1"
  if echo "$cmd" | grep -qE '\$\(|`|>|<|&[^&]|;|\\$\{[^}]*\}'; then return 0; fi
  if echo "$cmd" | grep -qE '(^|[[:space:]|;&])(rm|curl|wget|nc|ncat|sudo|chmod|chown|dd|mv|cp|ln|kill|killall|mkfifo|mknod|eval|exec|source|\.)([[:space:]]|$)'; then return 0; fi
  return 1
}

score_shell() {
  local check_file="$1"; local workdir="$2"
  local cmd; cmd="$(yq -r '.cmd' "$check_file")"
  local expect_regex; expect_regex="$(yq -r '.expect_regex // empty' "$check_file")"
  local expect_min; expect_min="$(yq -r '.expect_min // empty' "$check_file")"
  local expect_exact; expect_exact="$(yq -r '.expect_exact // empty' "$check_file")"
  local unsafe_opt_in; unsafe_opt_in="$(yq -r '.unsafe_shell // false' "$check_file" 2>/dev/null || echo false)"

  local has_expect_field
  has_expect_field="$(yq -o=json '.' "$check_file" | jq 'has("expect_regex") or has("expect_min") or has("expect_exact")')"
  if [[ "$has_expect_field" != "true" ]]; then
    jq -n \
      --arg cmd "$cmd" \
      '{
        kind: "shell",
        passed: false,
        failed_check_id: ("shell:" + $cmd),
        expected: "at least one expect_* field (expect_regex / expect_min / expect_exact)",
        actual: "none set - check YAML for typo like expected_*",
        diff_hint: "this check is misconfigured; treating as harness error",
        error: true
      }'
    return 0
  fi

  if [[ "$unsafe_opt_in" != "true" && "${EVAL_ALLOW_UNSAFE_SHELL:-0}" != "1" ]] && score_shell_is_unsafe "$cmd"; then
    jq -n \
      --arg cmd "$cmd" \
      '{
        kind: "shell",
        passed: false,
        failed_check_id: ("shell:" + $cmd),
        expected: "safe shell expression",
        actual: "rejected by safety filter",
        diff_hint: "command contains shell metacharacters or dangerous binaries (rm/curl/wget/sudo/etc.). Set `unsafe_shell: true` on this check or EVAL_ALLOW_UNSAFE_SHELL=1 to override.",
        error: true
      }'
    return 0
  fi

  local out
  out="$(cd "$workdir" && bash -c "$cmd" 2>&1 || true)"

  local passed="false"
  local diff_hint=""
  if [[ -n "$expect_regex" ]] && echo "$out" | grep -Eq "$expect_regex"; then
    passed="true"
  elif [[ -n "$expect_min" ]]; then
    local n; n="$(echo "$out" | tr -d ' \n')"
    if [[ "$n" =~ ^[0-9]+$ ]] && [[ "$n" -ge "$expect_min" ]]; then
      passed="true"
    else
      diff_hint="got=$out, expect_min=$expect_min"
    fi
  elif [[ -n "$expect_exact" ]] && [[ "$(echo "$out" | tr -d '\n')" == "$expect_exact" ]]; then
    passed="true"
  fi

  jq -n \
    --arg kind shell \
    --arg cmd "$cmd" \
    --arg out "$out" \
    --arg expect_regex "$expect_regex" \
    --arg expect_min "$expect_min" \
    --arg expect_exact "$expect_exact" \
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
  local contains_json; contains_json="$(yq -o=json '.contains' "$check_file")"

  local target="$workdir/$target_file"
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
  local full="$workdir/$target"
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
    match="$(grep -n -F "$needle" "$transcript" | head -1 || true)"
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

  local artifact_content=""
  if [[ -n "$target_file" && -f "$workdir/$target_file" ]]; then
    artifact_content="$(head -c 8000 "$workdir/$target_file")"
  elif [[ -f "$transcript" ]]; then
    artifact_content="$(head -c 8000 "$transcript")"
  fi

  local system_prompt="You are a strict, terse code-review judge. The skill under test produced an artifact. You will be given a rubric and the artifact. Reply with EXACTLY one of: PASS or FAIL on the first line, then up to 3 lines of justification. Do not hedge. Do not explain the rubric back. If the artifact is empty or unrelated, FAIL."
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
  match="$(grep -n -F "$needle" "$transcript" | head -1 || true)"
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
# Reads case_yaml's .checks[], runs each, aggregates into out_json.
run_all_checks() {
  local case_file="$1"; local workdir="$2"; local transcript="$3"; local out="$4"

  local n_checks; n_checks="$(yq -r '.checks | length' "$case_file")"
  local results=()

  local i=0
  while [[ $i -lt $n_checks ]]; do
    local tmp; tmp="$(mktemp)"
    yq -o=yaml ".checks[$i]" "$case_file" > "$tmp"
    local res; res="$(run_check "$tmp" "$workdir" "$transcript")"
    if [[ "${EVAL_AUTOFIX:-1}" == "1" ]]; then
      res="$(propose_fix "$res")"
    fi
    results+=("$res")
    rm -f "$tmp"
    i=$((i+1))
  done

  local results_json
  results_json="$(printf '%s\n' "${results[@]}" | jq -s .)"

  local all_passed
  all_passed="$(echo "$results_json" | jq 'map(.passed) | all')"

  jq -n \
    --argjson results "$results_json" \
    --argjson all_passed "$all_passed" \
    --arg total "$n_checks" \
    '{
      passed: $all_passed,
      total: ($total | tonumber),
      pass_count: ($results | map(select(.passed)) | length),
      fail_count: ($results | map(select(.passed | not)) | length),
      checks: $results
    }' > "$out"
}

export -f run_check run_all_checks score_shell score_jq_path_contains score_file_exists score_output_contains score_output_not_contains

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-}" in
    check) shift; run_check "$@" ;;
    all)   shift; run_all_checks "$@" ;;
    *) echo "usage: score.sh {check <check.yaml> <workdir> <transcript> | all <case.yaml> <workdir> <transcript> <out>}" >&2; exit 2 ;;
  esac
fi
