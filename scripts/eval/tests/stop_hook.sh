#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/../hooks/opencode-stop.sh"

WORK="$(mktemp -d -t eval-harness-stop.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

STUB_BIN="$WORK/bin"
mkdir -p "$STUB_BIN"

cat > "$STUB_BIN/opencode" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then echo "1.15.10-stub"; exit 0; fi
exit 0
STUB
chmod +x "$STUB_BIN/opencode"
export PATH="$STUB_BIN:$PATH"

OPENCODE_CHANGED_FILES="proj/.opencode/skills/foo/SKILL.md" bash "$HOOK" > "$WORK/out.log" 2>&1
RC=$?
if [[ "$RC" != "0" ]]; then echo "FAIL: hook should exit 0 on too-old opencode (got $RC)" >&2; cat "$WORK/out.log" >&2; exit 1; fi
grep -q "requires opencode >= 1.16" "$WORK/out.log" || { echo "FAIL: missing version-gate message" >&2; cat "$WORK/out.log" >&2; exit 1; }

cat > "$STUB_BIN/opencode" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then echo "1.17.0-stub"; exit 0; fi
exit 0
STUB
chmod +x "$STUB_BIN/opencode"

bash "$HOOK" > "$WORK/out2.log" 2>&1
RC=$?
if [[ "$RC" != "0" ]]; then echo "FAIL: hook should exit 0 on no changed files (got $RC)" >&2; cat "$WORK/out2.log" >&2; exit 1; fi
grep -q "no skill files changed" "$WORK/out2.log" || { echo "FAIL: missing no-skill-files message" >&2; cat "$WORK/out2.log" >&2; exit 1; }

echo "PASS: opencode Stop hook gates on version + handles empty changed-set"
exit 0
