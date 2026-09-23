#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/../lib/yq-shim.sh"
source "$SCRIPT_DIR/../lib/llm_judge.sh"
source "$SCRIPT_DIR/../lib/autofix.sh"
source "$SCRIPT_DIR/../lib/score.sh"

WORK="$(mktemp -d -t eval-harness-shell-exact-lines.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/pass.yaml" <<'YAML'
kind: shell
cmd: "printf 'first  \\nsecond\\t\\n\\n'"
expect_exact_lines:
  - first
  - second
YAML

out="$(score_shell "$WORK/pass.yaml" "$WORK")"
[[ "$(echo "$out" | jq -r '.passed')" == "true" ]] || {
  echo "FAIL: matching lines with trailing whitespace should pass" >&2
  echo "$out" >&2
  exit 1
}

cat > "$WORK/order-fail.yaml" <<'YAML'
kind: shell
cmd: "printf 'second\\nfirst\\n'"
expect_exact_lines:
  - first
  - second
YAML

out="$(score_shell "$WORK/order-fail.yaml" "$WORK")"
[[ "$(echo "$out" | jq -r '.passed')" == "false" ]] || {
  echo "FAIL: reordered lines should fail" >&2
  echo "$out" >&2
  exit 1
}
[[ "$(echo "$out" | jq -r '.diff_hint')" == *"expect_exact_lines"* ]] || {
  echo "FAIL: mismatch should identify expect_exact_lines" >&2
  echo "$out" >&2
  exit 1
}

cat > "$WORK/empty.yaml" <<'YAML'
kind: shell
cmd: "printf ''"
expect_exact_lines: []
YAML

out="$(score_shell "$WORK/empty.yaml" "$WORK")"
[[ "$(echo "$out" | jq -r '.passed')" == "true" ]] || {
  echo "FAIL: empty output should match an empty expected array" >&2
  echo "$out" >&2
  exit 1
}

echo "PASS: shell expect_exact_lines compares ordered lines and ignores trailing whitespace/blank lines"
exit 0
