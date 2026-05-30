#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ATTR="$SCRIPT_DIR/../lib/attribute.sh"

run() {
  local delta="$1"
  local expected_top="$2"
  local got
  got="$(bash "$ATTR" "$delta" | jq -r '.top')"
  if [[ "$got" != "$expected_top" ]]; then
    echo "FAIL: delta=$delta expected top=$expected_top got=$got" >&2
    exit 1
  fi
}

run '{"keys_changed":["skill_bundle_sha"],"details":{}}'  SKILL_CHANGED
run '{"keys_changed":["skill_sha"],"details":{}}'         SKILL_CHANGED
run '{"keys_changed":["fixture_sha"],"details":{}}'       FIXTURE_STALE
run '{"keys_changed":["model_id"],"details":{}}'          MODEL_CHANGED
run '{"keys_changed":["opencode_version"],"details":{}}'  MODEL_CHANGED
run '{"keys_changed":["__no_baseline__"],"details":{}}'   UNKNOWN_DRIFT
run '{"keys_changed":[],"details":{}}'                    UNKNOWN_DRIFT

multi="$(bash "$ATTR" '{"keys_changed":["skill_sha","fixture_sha"],"details":{}}')"
top="$(echo "$multi" | jq -r '.top')"
also="$(echo "$multi" | jq -r '.also_observed | join(",")')"
[[ "$top" == "SKILL_CHANGED" ]] || { echo "FAIL: multi top=$top expected SKILL_CHANGED" >&2; exit 1; }
[[ "$also" == "FIXTURE_STALE" ]] || { echo "FAIL: multi also=$also expected FIXTURE_STALE" >&2; exit 1; }

echo "PASS: attribution portable across grep flavors (BRE/ERE-safe)"
exit 0
