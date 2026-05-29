#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d -t eval-harness-reg.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

export EVAL_HARNESS_REGISTRY="$WORK/registry.yaml"

REG="$SCRIPT_DIR/../lib/registry.sh"

bash "$REG" init >/dev/null
[[ -f "$EVAL_HARNESS_REGISTRY" ]] || { echo "FAIL: init didn't create registry" >&2; exit 1; }

bash "$REG" enable foo >/dev/null
bash "$REG" enable bar >/dev/null
bash "$REG" enable foo >/dev/null

LIST="$(bash "$REG" list | tr '\n' ' ')"
[[ "$LIST" == "bar foo " ]] || { echo "FAIL: list expected 'bar foo ', got '$LIST'" >&2; exit 1; }

bash "$REG" is-enabled foo >/dev/null || { echo "FAIL: foo should be enabled" >&2; exit 1; }
bash "$REG" is-enabled missing 2>/dev/null && { echo "FAIL: 'missing' should not be enabled" >&2; exit 1; }

bash "$REG" disable foo >/dev/null
bash "$REG" is-enabled foo 2>/dev/null && { echo "FAIL: foo disabled but is-enabled returned 0" >&2; exit 1; }

mkdir -p "$WORK/myrepo/.git"
got="$(bash "$REG" repo-name "$WORK/myrepo")"
[[ "$got" == "myrepo" ]] || { echo "FAIL: repo-name expected 'myrepo', got '$got'" >&2; exit 1; }

mkdir -p "$WORK/myrepo/sub/nested"
got="$(bash "$REG" repo-name "$WORK/myrepo/sub/nested")"
[[ "$got" == "myrepo" ]] || { echo "FAIL: repo-name walked-up expected 'myrepo', got '$got'" >&2; exit 1; }

echo "PASS: registry init/enable/disable/list/is-enabled/repo-name all work"
exit 0
