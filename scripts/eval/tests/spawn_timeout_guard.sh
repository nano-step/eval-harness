#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

WORK="$(mktemp -d -t eval-harness-spawn.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

export OPENCODE_SKILLS_ROOT="$WORK/skills"
export EVAL_STATE_DIR="$WORK/state"
export EVAL_SKIP_AUTH_CHECK=1
export EVAL_MAX_SECONDS=1
mkdir -p "$OPENCODE_SKILLS_ROOT/test-skill/evals/cases"

cat > "$OPENCODE_SKILLS_ROOT/test-skill/evals/cases/c1.yaml" <<YAML
schema_version: 2
id: c1
mode: deterministic
skill_under_test: test-skill
skills_loaded: [test-skill]
description: hangs forever
prompt: hang
budget: {max_tokens: 100, max_seconds: 1}
checks:
  - kind: output_not_contains
    value: SOME_FORBIDDEN
YAML

STUB_BIN="$WORK/bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/opencode" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then echo "1.15.10-stub"; exit 0; fi
sleep 30
exit 0
STUB
chmod +x "$STUB_BIN/opencode"
export PATH="$STUB_BIN:$PATH"

bash "$REPO_ROOT/scripts/eval/run.sh" --skill=test-skill --case=c1 > "$WORK/out.log" 2>&1 || true

LATEST="$(ls -dt "$EVAL_STATE_DIR/runs"/* | head -1)"
CHECKS="$LATEST/c1/checks.json"
if [[ ! -f "$CHECKS" ]]; then
  echo "FAIL: checks.json not produced for timed-out case" >&2
  cat "$WORK/out.log" >&2
  exit 1
fi

KIND="$(jq -r '.checks[0].kind' "$CHECKS")"
ERR="$(jq -r '.checks[0].error // false' "$CHECKS")"
PASSED="$(jq -r '.checks[0].passed' "$CHECKS")"
ACTUAL="$(jq -r '.checks[0].actual' "$CHECKS")"

[[ "$KIND" == "harness_error" ]] || { echo "FAIL: kind=$KIND expected harness_error" >&2; cat "$CHECKS" >&2; exit 1; }
[[ "$ERR" == "true" ]] || { echo "FAIL: error=$ERR expected true" >&2; exit 1; }
[[ "$PASSED" == "false" ]] || { echo "FAIL: passed=$PASSED expected false" >&2; exit 1; }
[[ "$ACTUAL" == *"timeout"* ]] || { echo "FAIL: actual=$ACTUAL should mention timeout" >&2; exit 1; }

grep -q "timed out" "$WORK/out.log" || { echo "FAIL: stderr should mention 'timed out'" >&2; cat "$WORK/out.log" >&2; exit 1; }

echo "PASS: timeout(1) exit 124 surfaces as harness_error check, never silent partial-transcript score"
exit 0
