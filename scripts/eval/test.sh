#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_DIR="$SCRIPT_DIR/tests"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
failed=0
count=0
for test_file in "$TEST_DIR"/*.sh; do
  [[ -f "$test_file" ]] || continue
  name="$(basename "$test_file" .sh)"
  count=$((count+1))
  if bash "$test_file" > "$TMP/$name.log" 2>&1; then
    echo "PASS $name"
  else
    code=$?
    echo "FAIL $name (exit $code)" >&2
    cat "$TMP/$name.log" >&2
    failed=1
  fi
done
if [[ "$count" -eq 0 ]]; then
  echo "no evaluation tests found under $TEST_DIR" >&2
  exit 2
fi
[[ "$failed" -eq 0 ]] || exit 1
echo "PASS all $count evaluation test suites"
