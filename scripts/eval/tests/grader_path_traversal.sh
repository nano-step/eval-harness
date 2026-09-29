#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
WORK="$(mktemp -d -t eval-harness-grader-paths.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/workdir"
printf '{"secret":["CANARY"]}\n' > "$WORK/private.json"
ln -s "$WORK/private.json" "$WORK/workdir/private-link.json"
source "$REPO_ROOT/scripts/eval/lib/score.sh"

assert_rejected() {
  local check_file="$1" name="$2" result
  result="$(run_check "$check_file" "$WORK/workdir" "$WORK/transcript.jsonl")"
  [[ "$(printf '%s' "$result" | jq -r '.status')" == "ERROR" ]] || {
    echo "FAIL: $name path was not rejected: $result" >&2
    exit 1
  }
  [[ "$result" != *CANARY* ]] || { echo "FAIL: $name exposed data outside workdir" >&2; exit 1; }
}

cat > "$WORK/jq-traversal.yaml" <<'YAML'
kind: jq_path_contains
file: ../private.json
path: .secret
contains: [CANARY]
YAML
assert_rejected "$WORK/jq-traversal.yaml" jq_path_contains

cat > "$WORK/file-traversal.yaml" <<'YAML'
kind: file_exists
path: ../private.json
YAML
assert_rejected "$WORK/file-traversal.yaml" file_exists

cat > "$WORK/symlink-escape.yaml" <<'YAML'
kind: jq_path_contains
file: private-link.json
path: .secret
contains: [CANARY]
YAML
assert_rejected "$WORK/symlink-escape.yaml" symlink

cat > "$WORK/judge-traversal.yaml" <<'YAML'
kind: llm_judge
rubric: "Check the artifact."
target_file: ../private.json
YAML
EVAL_LLM_JUDGE_LIVE=0 assert_rejected "$WORK/judge-traversal.yaml" llm_judge

echo "PASS: jq, file_exists, and llm_judge file paths stay inside workdir"
