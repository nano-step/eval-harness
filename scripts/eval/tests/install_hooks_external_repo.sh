#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
WORK="$(mktemp -d -t eval-harness-hook-install.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
CONSUMER="$WORK/consumer"
mkdir -p "$CONSUMER"
git init -q "$CONSUMER"
export EVAL_STATE_DIR="$WORK/state"

bash "$REPO_ROOT/scripts/eval/install-hooks.sh" "$CONSUMER" > "$WORK/install.out"
[[ -x "$CONSUMER/.git/hooks/pre-push" ]] || { echo "FAIL: pre-push wrapper was not installed" >&2; exit 1; }

set +e
(cd "$CONSUMER" && bash .git/hooks/pre-push origin https://example.invalid/repo.git </dev/null) > "$WORK/hook.out" 2> "$WORK/hook.err"
rc=$?
set -e
[[ "$rc" -eq 0 ]] || { echo "FAIL: installed hook could not load harness libraries in a consumer repo (exit $rc)" >&2; cat "$WORK/hook.err" >&2; exit 1; }
! grep -q "libraries not found" "$WORK/hook.err" || { echo "FAIL: installed hook resolved libraries from the consumer repo" >&2; exit 1; }

echo "PASS: per-repo hook wrapper resolves libraries from the harness checkout"
