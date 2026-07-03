#!/usr/bin/env bash
# lib/attribute.sh — 4-class attribution decision tree (Settled Decision #10)
# Classes: SKILL_CHANGED | FIXTURE_STALE | MODEL_CHANGED | UNKNOWN_DRIFT

set -euo pipefail

# Usage: attribute <env_delta_json>
# Reads a manifest-diff JSON ({keys_changed: [...], details: {...}})
# Emits: {top: "<CLASS>", also_observed: [...], evidence: <details>}
attribute() {
  local delta_json="$1"

  local changed
  changed="$(echo "$delta_json" | jq -r '.keys_changed[]' 2>/dev/null || true)"

  local classes=()

  if echo "$changed" | grep -qE "^(skill_bundle_sha|skill_sha|graph_fingerprint)$"; then
    classes+=("SKILL_CHANGED")
  fi
  if echo "$changed" | grep -qE "^fixture_sha$"; then
    classes+=("FIXTURE_STALE")
  fi
  if echo "$changed" | grep -qE "^(model_id|opencode_version|langgraph_version)$"; then
    classes+=("MODEL_CHANGED")
  fi

  if [[ ${#classes[@]} -eq 0 ]]; then
    classes=("UNKNOWN_DRIFT")
  fi

  local top="${classes[0]}"
  local also=()
  if [[ ${#classes[@]} -gt 1 ]]; then
    also=("${classes[@]:1}")
  fi

  local also_json
  if [[ ${#also[@]} -eq 0 ]]; then
    also_json="[]"
  else
    also_json="$(printf '%s\n' "${also[@]}" | jq -R . | jq -s .)"
  fi

  jq -n \
    --arg top "$top" \
    --argjson also "$also_json" \
    --argjson evidence "$delta_json" \
    '{top: $top, also_observed: $also, evidence: $evidence}'
}

export -f attribute

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  attribute "$@"
fi
