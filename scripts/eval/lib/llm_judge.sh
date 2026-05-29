#!/usr/bin/env bash
set -euo pipefail

_LLM_JUDGE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

JUDGE_DEFAULT_MODEL="${EVAL_LLM_JUDGE_MODEL:-claude-sonnet-4-6}"
JUDGE_API_URL="${ANTHROPIC_API_URL:-https://api.anthropic.com/v1/messages}"
JUDGE_API_VERSION="${ANTHROPIC_API_VERSION:-2023-06-01}"

llm_judge_call_once() {
  local model="$1"
  local system_prompt="$2"
  local user_prompt="$3"
  local key="${ANTHROPIC_API_KEY:-}"
  if [[ -z "$key" || "$key" == *REDACTED* || ${#key} -lt 20 ]]; then
    echo '{"verdict": null, "reason": "judge_unavailable: ANTHROPIC_API_KEY missing or invalid"}'
    return 0
  fi

  local short_model="${model#anthropic/}"
  local body
  body="$(jq -n \
    --arg model "$short_model" \
    --arg sys "$system_prompt" \
    --arg user "$user_prompt" \
    '{
      model: $model,
      max_tokens: 1024,
      system: $sys,
      messages: [{"role":"user", "content": $user}]
    }')"

  local resp
  if [[ "${EVAL_LLM_JUDGE_LIVE:-1}" == "0" ]]; then
    echo '{"verdict": null, "reason": "judge_unavailable: EVAL_LLM_JUDGE_LIVE=0"}'
    return 0
  fi

  resp="$(curl -sS \
    --max-time "${EVAL_LLM_JUDGE_TIMEOUT:-30}" \
    -H "x-api-key: $key" \
    -H "anthropic-version: $JUDGE_API_VERSION" \
    -H "content-type: application/json" \
    -d "$body" \
    "$JUDGE_API_URL" 2>&1)" || {
      echo "{\"verdict\": null, \"reason\": \"judge_unavailable: curl_failed: $(printf '%s' "$resp" | head -c 200 | jq -Rs .)\"}"
      return 0
    }

  local content
  content="$(echo "$resp" | jq -r '.content[0].text // ""' 2>/dev/null || echo "")"
  if [[ -z "$content" ]]; then
    local err_msg
    err_msg="$(echo "$resp" | jq -r '.error.message // "no_content"' 2>/dev/null || echo "no_content")"
    jq -n --arg reason "judge_unavailable: $err_msg" '{verdict: null, reason: $reason}'
    return 0
  fi

  local verdict
  verdict="$(echo "$content" | grep -oE '"(PASS|FAIL)"' | head -1 | tr -d '"' || true)"
  if [[ -z "$verdict" ]]; then
    verdict="$(echo "$content" | grep -oE '\b(PASS|FAIL)\b' | head -1 || true)"
  fi
  if [[ -z "$verdict" ]]; then
    jq -n --arg c "$(printf '%s' "$content" | head -c 200)" '{verdict: null, reason: "judge_unavailable: could_not_parse_verdict", raw: $c}'
    return 0
  fi

  jq -n --arg v "$verdict" --arg raw "$(printf '%s' "$content" | head -c 500)" \
    '{verdict: $v, reason: "ok", raw: $raw}'
}

llm_judge_majority() {
  local model="$1"
  local system_prompt="$2"
  local user_prompt="$3"
  local n="${4:-3}"

  local results=()
  for ((i=0; i<n; i++)); do
    results+=("$(llm_judge_call_once "$model" "$system_prompt" "$user_prompt")")
  done

  local results_json
  results_json="$(printf '%s\n' "${results[@]}" | jq -s .)"

  local pass_count fail_count null_count
  pass_count="$(echo "$results_json" | jq '[.[] | select(.verdict == "PASS")] | length')"
  fail_count="$(echo "$results_json" | jq '[.[] | select(.verdict == "FAIL")] | length')"
  null_count="$(echo "$results_json" | jq '[.[] | select(.verdict == null)] | length')"

  local majority_verdict="null"
  local reason="ok"
  if [[ "$null_count" -ge $(( (n + 1) / 2 )) ]]; then
    majority_verdict="null"
    reason="judge_unavailable_majority"
  elif [[ "$pass_count" -gt "$fail_count" ]]; then
    majority_verdict='"PASS"'
  elif [[ "$fail_count" -gt "$pass_count" ]]; then
    majority_verdict='"FAIL"'
  else
    majority_verdict="null"
    reason="tied_or_inconclusive"
  fi

  jq -n \
    --argjson samples "$n" \
    --argjson pass "$pass_count" \
    --argjson fail "$fail_count" \
    --argjson nulls "$null_count" \
    --argjson verdict "$majority_verdict" \
    --argjson per_sample "$results_json" \
    --arg reason "$reason" \
    '{
      samples: $samples,
      pass_count: $pass,
      fail_count: $fail,
      null_count: $nulls,
      majority_verdict: $verdict,
      reason: $reason,
      per_sample: $per_sample
    }'
}

export -f llm_judge_call_once llm_judge_majority

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-}" in
    once)     shift; llm_judge_call_once "${1:-$JUDGE_DEFAULT_MODEL}" "$2" "$3" ;;
    majority) shift; llm_judge_majority  "${1:-$JUDGE_DEFAULT_MODEL}" "$2" "$3" "${4:-3}" ;;
    *) echo "usage: llm_judge.sh {once|majority} <model> <system_prompt> <user_prompt> [n]" >&2; exit 2 ;;
  esac
fi
