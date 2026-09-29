#!/usr/bin/env bash
# Attribution is evidence classification, not causal proof.
set -euo pipefail

attribute() {
  local delta_json="$1"
  local changed
  changed="$(printf '%s' "$delta_json" | jq -r '.keys_changed[]' 2>/dev/null || true)"
  local sut_changed=0 bundle_changed=0
  printf '%s\n' "$changed" | grep -qE '^skill_sha$' && sut_changed=1
  printf '%s\n' "$changed" | grep -qE '^skill_bundle_sha$' && bundle_changed=1

  local suspected_json suspected_count
  suspected_json="$(printf '%s' "$delta_json" | jq -c '
    (.details.per_skill_sha // {}) as $d
    | ($d.baseline // {}) as $b | ($d.current // {}) as $c
    | [ (($b|keys)+($c|keys)) | unique[] | select($b[.] != $c[.]) ]
  ' 2>/dev/null || echo '[]')"
  suspected_count="$(printf '%s' "$suspected_json" | jq 'length' 2>/dev/null || echo 0)"
  local classes=() baseline_tool current_tool
  if [[ "$sut_changed" == "1" ]]; then classes+=("SKILL_CHANGED")
  elif [[ "$bundle_changed" == "1" ]]; then
    if [[ "$suspected_count" -gt 0 ]]; then classes+=("CROSS_SKILL_CHANGE"); else classes+=("SKILL_CHANGED"); fi
  fi
  printf '%s\n' "$changed" | grep -qE '^graph_fingerprint$' && classes+=("SKILL_CHANGED")
  printf '%s\n' "$changed" | grep -qE '^fixture_sha$' && classes+=("FIXTURE_STALE")
  printf '%s\n' "$changed" | grep -qE '^(model_id|opencode_version|langgraph_version)$' && classes+=("MODEL_CHANGED")
  printf '%s\n' "$changed" | grep -qE '^prompt_sha$' && classes+=("PROMPT_CHANGED")
  printf '%s\n' "$changed" | grep -qE '^rubric_sha$' && classes+=("RUBRIC_CHANGED")
  printf '%s\n' "$changed" | grep -qE '^(node_version|platform|python_version|runner|runner_config_sha)$' && classes+=("ENVIRONMENT_CHANGED")
  if printf '%s\n' "$changed" | grep -qE '^tool_manifest_sha$'; then
    baseline_tool="$(printf '%s' "$delta_json" | jq -r '.details.tool_manifest_sha.baseline // empty')"
    current_tool="$(printf '%s' "$delta_json" | jq -r '.details.tool_manifest_sha.current // empty')"
    if [[ -n "$baseline_tool" && -n "$current_tool" ]]; then classes+=("TOOL_MANIFEST_CHANGED")
    else classes+=("EVIDENCE_AVAILABILITY_CHANGED"); fi
  fi
  [[ "+$changed+" == *"+__no_baseline__+"* ]] && classes+=("NO_BASELINE")
  if [[ ${#classes[@]} -eq 0 ]]; then classes=("UNKNOWN_DRIFT"); fi

  local top="${classes[0]}" also=() also_json='[]'
  if [[ ${#classes[@]} -gt 1 ]]; then also=("${classes[@]:1}"); also_json="$(printf '%s\n' "${also[@]}" | jq -R . | jq -s .)"; fi
  local level explanation
  case "$top" in
    UNKNOWN_DRIFT|NO_BASELINE) level="limited"; explanation="No comparable baseline evidence identifies a change class." ;;
    CROSS_SKILL_CHANGE) level="direct_hash_observation"; explanation="Per-skill hashes identify other changed skills; this is co-occurrence evidence, not proof of causality." ;;
    *) level="direct_hash_observation"; explanation="The classified manifest field changed; association does not establish causality." ;;
  esac
  local out
  out="$(jq -n --arg top "$top" --argjson also "$also_json" --argjson evidence "$delta_json" --arg level "$level" --arg explanation "$explanation" \
    '{top:$top,also_observed:$also,evidence:$evidence,evidence_strength:$level,explanation:$explanation}')"
  if [[ "$top" == "CROSS_SKILL_CHANGE" ]]; then out="$(printf '%s' "$out" | jq --argjson skills "$suspected_json" '. + {suspected_skills:$skills}')"; fi
  printf '%s\n' "$out"
}

export -f attribute
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then attribute "$@"; fi

