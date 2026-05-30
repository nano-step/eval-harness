#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/../lib/yq-shim.sh"
source "$SCRIPT_DIR/../lib/llm_judge.sh"
source "$SCRIPT_DIR/../lib/autofix.sh"
source "$SCRIPT_DIR/../lib/score.sh"

WORK="$(mktemp -d -t eval-harness-trans.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/check.yaml" <<YAML
kind: output_not_contains
value: FORBIDDEN_STRING
YAML

out="$(score_output_not_contains "$WORK/check.yaml" "$WORK/does-not-exist.jsonl")"
passed="$(echo "$out" | jq -r '.passed')"
err="$(echo "$out" | jq -r '.error // false')"
hint="$(echo "$out" | jq -r '.diff_hint')"
[[ "$passed" == "false" ]] || { echo "FAIL: missing transcript should FAIL not PASS, got passed=$passed" >&2; echo "$out" >&2; exit 1; }
[[ "$err" == "true" ]] || { echo "FAIL: missing transcript should error=true, got $err" >&2; exit 1; }
[[ "$hint" == *"transcript missing"* ]] || { echo "FAIL: hint should mention 'transcript missing', got: $hint" >&2; exit 1; }

: > "$WORK/empty.jsonl"
out="$(score_output_not_contains "$WORK/check.yaml" "$WORK/empty.jsonl")"
passed="$(echo "$out" | jq -r '.passed')"
err="$(echo "$out" | jq -r '.error // false')"
hint="$(echo "$out" | jq -r '.diff_hint')"
[[ "$passed" == "false" ]] || { echo "FAIL: empty transcript should FAIL not PASS, got passed=$passed" >&2; echo "$out" >&2; exit 1; }
[[ "$err" == "true" ]] || { echo "FAIL: empty transcript should error=true, got $err" >&2; exit 1; }
[[ "$hint" == *"transcript empty"* ]] || { echo "FAIL: hint should mention 'transcript empty', got: $hint" >&2; exit 1; }

echo '{"event":"assistant_message","content":"some clean output"}' > "$WORK/clean.jsonl"
out="$(score_output_not_contains "$WORK/check.yaml" "$WORK/clean.jsonl")"
passed="$(echo "$out" | jq -r '.passed')"
[[ "$passed" == "true" ]] || { echo "FAIL: clean transcript without forbidden string should PASS, got passed=$passed" >&2; echo "$out" >&2; exit 1; }

echo '{"event":"assistant_message","content":"FORBIDDEN_STRING leaked"}' > "$WORK/bad.jsonl"
out="$(score_output_not_contains "$WORK/check.yaml" "$WORK/bad.jsonl")"
passed="$(echo "$out" | jq -r '.passed')"
[[ "$passed" == "false" ]] || { echo "FAIL: transcript with forbidden string should FAIL, got passed=$passed" >&2; exit 1; }

echo "PASS: output_not_contains correctly errors on missing/empty transcript; works normally on real transcripts"
exit 0
