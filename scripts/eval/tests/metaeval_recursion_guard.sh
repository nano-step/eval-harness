#!/usr/bin/env bash
# Regression test for EV-1 (SD-5): metaeval must refuse to run when a real `opencode` is on
# PATH — driving it unstubbed would spawn paid sessions (recursion/token bomb).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

WORK="$(mktemp -d -t eval-metaguard.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"
# A stand-in "real" opencode binary on PATH.
printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/bin/opencode"
chmod +x "$WORK/bin/opencode"

set +e
PATH="$WORK/bin:$PATH" bash "$REPO_ROOT/scripts/eval/metaeval.sh" >"$WORK/log" 2>&1
rc=$?
set -e
[[ "$rc" -eq 2 ]] || { echo "FAIL: metaeval should abort (exit 2) when a real opencode is on PATH, got $rc" >&2; cat "$WORK/log" >&2; exit 1; }
grep -qi "stub-only" "$WORK/log" || { echo "FAIL: abort message should explain stub-only requirement" >&2; cat "$WORK/log" >&2; exit 1; }

# Escape hatch is honored (won't actually run far, but must NOT abort on the guard).
set +e
PATH="$WORK/bin:$PATH" EVAL_METAEVAL_ALLOW_REAL=1 bash "$REPO_ROOT/scripts/eval/metaeval.sh" --corpus="$WORK/empty" >"$WORK/log2" 2>&1
rc=$?
set -e
grep -qi "stub-only" "$WORK/log2" && { echo "FAIL: EVAL_METAEVAL_ALLOW_REAL=1 should bypass the guard" >&2; exit 1; }

echo "PASS: metaeval refuses to run with a real opencode on PATH (recursion guard); allow-flag bypasses"
exit 0
