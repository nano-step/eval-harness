#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/../lib/yq-shim.sh"
source "$SCRIPT_DIR/../lib/llm_judge.sh"
source "$SCRIPT_DIR/../lib/autofix.sh"
source "$SCRIPT_DIR/../lib/score.sh"

WORK="$(mktemp -d -t eval-harness-shell-no-expect.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/no-expectation.yaml" <<YAML
kind: shell
cmd: "printf ok"
YAML

out="$(score_shell "$WORK/no-expectation.yaml" "$WORK")"
passed="$(echo "$out" | jq -r '.passed')"
err="$(echo "$out" | jq -r '.error // false')"
expected="$(echo "$out" | jq -r '.expected')"
actual="$(echo "$out" | jq -r '.actual')"
hint="$(echo "$out" | jq -r '.diff_hint')"

[[ "$passed" == "false" ]] || { echo "FAIL: missing expectations should not pass" >&2; echo "$out" >&2; exit 1; }
[[ "$err" == "true" ]] || { echo "FAIL: missing expectations should set error=true, got $err" >&2; echo "$out" >&2; exit 1; }
[[ "$expected" == *"expect_regex"* ]] || { echo "FAIL: expected should mention expect_* fields, got: $expected" >&2; exit 1; }
[[ "$actual" == *"none set"* ]] || { echo "FAIL: actual should mention no expectations, got: $actual" >&2; exit 1; }
[[ "$hint" == *"misconfigured"* ]] || { echo "FAIL: hint should identify a misconfigured check, got: $hint" >&2; exit 1; }

echo "PASS: shell checks with no expect_* fields surface as harness errors"
exit 0
