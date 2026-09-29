#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

write_case() {
  local id="$1" kind="$2"
  mkdir -p "$TMP/$id/workdir"
  printf '{"schema_version":4,"model_id":"test/model","opencode_version":"test"}\n' > "$TMP/$id/env-manifest.json"
  case "$kind" in
    file_exists)
      printf 'present\n' > "$TMP/$id/workdir/result.txt"
      cat > "$TMP/$id/case.yaml" <<YAML
schema_version: 2
id: $id
eval_type: capability
checks:
  - kind: file_exists
    path: result.txt
YAML
      : > "$TMP/$id/transcript.jsonl" ;;
    output_contains)
      cat > "$TMP/$id/case.yaml" <<YAML
schema_version: 2
id: $id
eval_type: capability
checks:
  - kind: output_contains
    value: seen
YAML
      ;; # Deliberately no transcript evidence.
  esac
  source "$SCRIPT_DIR/lib/yq-shim.sh"
  source "$SCRIPT_DIR/lib/grading_manifest.sh"
  write_case_grading_manifest "$TMP/$id/case.yaml" "$TMP/$id/workdir" "$TMP/$id/transcript.jsonl" "$TMP/$id/env-manifest.json" "run-$id" "$id" "$TMP/$id/grading-manifest.json"
}

write_case manifest-pass file_exists
pass_result="$(bash "$SCRIPT_DIR/grade.sh" --manifest="$TMP/manifest-pass/grading-manifest.json" --strict)"
[[ "$(printf '%s' "$pass_result" | jq -r '.status')" == "PASS" ]]
echo 'PASS external manifest validates and grades file evidence'

printf 'tampered\n' >> "$TMP/manifest-pass/workdir/result.txt"
set +e
tamper_result="$(bash "$SCRIPT_DIR/grade.sh" --manifest="$TMP/manifest-pass/grading-manifest.json" --strict)"
tamper_code=$?
set -e
[[ "$tamper_code" -eq 13 ]]
[[ "$(printf '%s' "$tamper_result" | jq -r '.status')" == "ERROR" ]]
echo 'PASS tampered workdir is rejected before grading'

write_case manifest-transcript-missing output_contains
set +e
missing_result="$(bash "$SCRIPT_DIR/grade.sh" --manifest="$TMP/manifest-transcript-missing/grading-manifest.json" --strict)"
missing_code=$?
set -e
[[ "$missing_code" -eq 16 ]]
[[ "$(printf '%s' "$missing_result" | jq -r '.status')" == "INDETERMINATE" ]]
echo 'PASS unavailable transcript yields INDETERMINATE, not failure or pass'

jq '.evidence.workdir.path="../escape"' "$TMP/manifest-pass/grading-manifest.json" > "$TMP/manifest-pass/unsafe.json"
set +e
unsafe_result="$(bash "$SCRIPT_DIR/grade.sh" --manifest="$TMP/manifest-pass/unsafe.json" --strict)"
unsafe_code=$?
set -e
[[ "$unsafe_code" -eq 13 ]]
[[ "$(printf '%s' "$unsafe_result" | jq -r '.status')" == "ERROR" ]]
echo 'PASS traversal paths are rejected'
