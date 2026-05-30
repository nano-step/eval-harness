#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

WORK="$(mktemp -d -t eval-harness-traversal.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

export OPENCODE_SKILLS_ROOT="$WORK/skills"
export EVAL_STATE_DIR="$WORK/state"
export EVAL_SKIP_AUTH_CHECK=1
mkdir -p "$OPENCODE_SKILLS_ROOT/evil/evals/cases" \
         "$OPENCODE_SKILLS_ROOT/evil/evals/fixtures"

echo "innocent payload" > "$OPENCODE_SKILLS_ROOT/evil/evals/fixtures/payload.txt"

cat > "$OPENCODE_SKILLS_ROOT/evil/evals/cases/abs-path.yaml" <<YAML
schema_version: 2
id: abs-path
mode: deterministic
skill_under_test: evil
skills_loaded: [evil]
description: "Tries to write to absolute path"
setup:
  fixtures:
    "/tmp/eval-harness-pwned.txt": fixtures/payload.txt
prompt: noop
budget: {max_tokens: 1, max_seconds: 1}
checks:
  - kind: file_exists
    path: nonexistent
YAML

cat > "$OPENCODE_SKILLS_ROOT/evil/evals/cases/dotdot.yaml" <<YAML
schema_version: 2
id: dotdot
mode: deterministic
skill_under_test: evil
skills_loaded: [evil]
description: "Tries dotdot escape"
setup:
  fixtures:
    "../../../etc/pwned.txt": fixtures/payload.txt
prompt: noop
budget: {max_tokens: 1, max_seconds: 1}
checks:
  - kind: file_exists
    path: nonexistent
YAML

cat > "$OPENCODE_SKILLS_ROOT/evil/evals/cases/normal.yaml" <<YAML
schema_version: 2
id: normal
mode: deterministic
skill_under_test: evil
skills_loaded: [evil]
description: "Normal fixture"
setup:
  fixtures:
    "input.txt": fixtures/payload.txt
prompt: noop
budget: {max_tokens: 1, max_seconds: 1}
checks:
  - kind: file_exists
    path: input.txt
YAML

STUB_BIN="$WORK/bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/opencode" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then echo "1.15.10-stub"; exit 0; fi
exit 0
STUB
chmod +x "$STUB_BIN/opencode"
export PATH="$STUB_BIN:$PATH"

bash "$REPO_ROOT/scripts/eval/run.sh" --skill=evil --case=abs-path > "$WORK/abs.log" 2>&1 || true
grep -q "rejecting fixture dest='/tmp" "$WORK/abs.log" || {
  echo "FAIL: absolute path NOT rejected" >&2
  cat "$WORK/abs.log" >&2
  exit 1
}
[[ ! -f "/tmp/eval-harness-pwned.txt" ]] || {
  echo "FAIL: traversal succeeded — /tmp/eval-harness-pwned.txt exists" >&2
  rm -f /tmp/eval-harness-pwned.txt
  exit 1
}

bash "$REPO_ROOT/scripts/eval/run.sh" --skill=evil --case=dotdot > "$WORK/dot.log" 2>&1 || true
grep -qE "rejecting fixture dest='\.\./" "$WORK/dot.log" || {
  echo "FAIL: ../ escape NOT rejected" >&2
  cat "$WORK/dot.log" >&2
  exit 1
}

bash "$REPO_ROOT/scripts/eval/run.sh" --skill=evil --case=normal > "$WORK/norm.log" 2>&1 || true
LATEST="$(ls -dt "$EVAL_STATE_DIR/runs"/* | head -1)"
if [[ ! -f "$LATEST/normal/workdir/input.txt" ]]; then
  echo "FAIL: normal fixture NOT copied to workdir" >&2
  ls -la "$LATEST/normal/workdir/" >&2 || true
  exit 1
fi

echo "PASS: fixture path traversal blocked (absolute + ../) without breaking normal fixtures"
exit 0
