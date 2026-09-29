#!/usr/bin/env bash
# Regression test for #9: spawn.sh must NOT prepend the case workdir to PATH, so a
# fixture file named `jq` in the workdir cannot shadow the real binary for the opencode
# subprocess.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

WORK="$(mktemp -d -t eval-harness-shadow.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

# Static guard: the dangerous PATH prepend must be gone.
if grep -Eq 'export PATH="\$workdir:\$PATH"' "$SCRIPT_DIR/../lib/spawn.sh"; then
  echo "FAIL: spawn.sh still prepends \$workdir to PATH" >&2
  exit 1
fi

export OPENCODE_SKILLS_ROOT="$WORK/skills"; mkdir -p "$OPENCODE_SKILLS_ROOT"
source "$SCRIPT_DIR/../lib/spawn.sh"

WORKDIR="$WORK/workdir"; mkdir -p "$WORKDIR"
# A malicious fixture binary that would shadow the real jq if workdir were on PATH.
cat > "$WORKDIR/jq" <<'FAKE'
#!/usr/bin/env bash
echo "SHADOWED-FAKE-JQ"
FAKE
chmod +x "$WORKDIR/jq"

STUB_BIN="$WORK/bin"; mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/opencode" <<'STUB'
#!/usr/bin/env bash
[[ "${1:-}" == "--version" ]] && { echo "1.15.10-stub"; exit 0; }
# Whatever `jq` resolves to from inside the spawned process goes to the transcript.
jq --version 2>&1 || true
STUB
chmod +x "$STUB_BIN/opencode"
export PATH="$STUB_BIN:$PATH"
export EVAL_MAX_SECONDS=10
export EVAL_SKIP_AUTH_CHECK=1

TRANSCRIPT="$WORK/transcript.jsonl"
spawn_opencode "do something" "$WORKDIR" "$WORK/sandbox" "$TRANSCRIPT" >/dev/null 2>&1 || true

if grep -q "SHADOWED-FAKE-JQ" "$TRANSCRIPT" 2>/dev/null; then
  echo "FAIL: workdir fixture jq shadowed the real binary (PATH prepend leak)" >&2
  cat "$TRANSCRIPT" >&2
  exit 1
fi

echo "PASS: workdir fixture cannot shadow system binaries (no PATH prepend)"
exit 0
