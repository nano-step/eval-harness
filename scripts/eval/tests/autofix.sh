#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AUTOFIX="$SCRIPT_DIR/../lib/autofix.sh"

source "$SCRIPT_DIR/../lib/autofix.sh"

oc_fail='{
  "kind": "output_contains",
  "passed": false,
  "failed_check_id": "output_contains:HELLO",
  "expected": "HELLO",
  "actual": "absent",
  "diff_hint": "transcript does not contain: HELLO"
}'
result="$(propose_fix "$oc_fail")"
kind="$(echo "$result" | jq -r '.fix_proposal.kind')"
snippet="$(echo "$result" | jq -r '.fix_proposal.patch_snippet')"
[[ "$kind" == "literal_string_missing" ]] || { echo "FAIL: oc kind=$kind" >&2; exit 1; }
[[ "$snippet" == "HELLO" ]] || { echo "FAIL: oc snippet=$snippet" >&2; exit 1; }

onc_fail='{
  "kind": "output_not_contains",
  "passed": false,
  "failed_check_id": "output_not_contains:FORBIDDEN",
  "expected": "absence of FORBIDDEN",
  "actual": "present",
  "diff_hint": "transcript contains forbidden: FORBIDDEN"
}'
result="$(propose_fix "$onc_fail")"
kind="$(echo "$result" | jq -r '.fix_proposal.kind')"
snippet="$(echo "$result" | jq -r '.fix_proposal.patch_snippet')"
[[ "$kind" == "forbidden_string_present" ]] || { echo "FAIL: onc kind=$kind" >&2; exit 1; }
[[ "$snippet" == "FORBIDDEN" ]] || { echo "FAIL: onc snippet=$snippet" >&2; exit 1; }

jpc_fail='{
  "kind": "jq_path_contains",
  "passed": false,
  "failed_check_id": "jq_path_contains:atoms.json:.tags[]",
  "expected": ["a", "b", "architecture"],
  "actual": ["a", "b"],
  "diff_hint": "missing from .tags[]: [\"architecture\"]"
}'
result="$(propose_fix "$jpc_fail")"
kind="$(echo "$result" | jq -r '.fix_proposal.kind')"
snippet="$(echo "$result" | jq -r '.fix_proposal.patch_snippet')"
[[ "$kind" == "jq_path_missing_values" ]] || { echo "FAIL: jpc kind=$kind" >&2; exit 1; }
[[ "$snippet" == *"architecture"* ]] || { echo "FAIL: jpc snippet=$snippet" >&2; exit 1; }

fe_fail='{
  "kind": "file_exists",
  "passed": false,
  "failed_check_id": "file_exists:review.md",
  "expected": "file present",
  "actual": "missing",
  "diff_hint": "expected file at review.md"
}'
result="$(propose_fix "$fe_fail")"
kind="$(echo "$result" | jq -r '.fix_proposal.kind')"
snippet="$(echo "$result" | jq -r '.fix_proposal.patch_snippet')"
[[ "$kind" == "missing_file" ]] || { echo "FAIL: fe kind=$kind" >&2; exit 1; }
[[ "$snippet" == "review.md" ]] || { echo "FAIL: fe snippet=$snippet" >&2; exit 1; }

llm_fail='{
  "kind": "llm_judge",
  "passed": false,
  "failed_check_id": "llm_judge:must flag SQL injection",
  "expected": "PASS verdict (majority)",
  "actual": "FAIL",
  "diff_hint": ""
}'
result="$(propose_fix "$llm_fail")"
fp="$(echo "$result" | jq -r '.fix_proposal')"
[[ "$fp" == "null" ]] || { echo "FAIL: llm_judge should yield null fix_proposal, got '$fp'" >&2; exit 1; }

oc_pass='{
  "kind": "output_contains",
  "passed": true,
  "failed_check_id": "output_contains:OK",
  "expected": "OK",
  "actual": "present",
  "diff_hint": ""
}'
result="$(propose_fix "$oc_pass")"
fp="$(echo "$result" | jq -r '.fix_proposal')"
[[ "$fp" == "null" ]] || { echo "FAIL: passing check should yield null fix_proposal, got '$fp'" >&2; exit 1; }

echo "PASS: autofix — output_contains, output_not_contains, jq_path_contains, file_exists all propose; llm_judge / passes return null"
exit 0
