#!/usr/bin/env bash
# Verify a generated missing-file proposal reaches apply and remains confined under target-dir.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
WORK="$(mktemp -d -t eval-harness-apply.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

export EVAL_STATE_DIR="$WORK/state"
export OPENCODE_SKILLS_ROOT="$WORK/skills"
export EVAL_SKIP_AUTH_CHECK=1
export EVAL_AUTOFIX=1
CASE_DIR="$OPENCODE_SKILLS_ROOT/sut/evals/cases"
STUB_BIN="$WORK/bin"
TARGET="$WORK/target"
OUTSIDE="$WORK/outside"
mkdir -p "$CASE_DIR" "$STUB_BIN" "$TARGET" "$OUTSIDE"

cat > "$CASE_DIR/missing.yaml" <<'YAML'
schema_version: 2
id: missing
prompt: create the requested file
eval_type: capability
checks:
  - kind: file_exists
    path: generated.txt
YAML

cat > "$STUB_BIN/opencode" <<'STUB'
#!/usr/bin/env bash
[[ "${1:-}" == "--version" ]] && { echo "1.15.10-stub"; exit 0; }
echo "{}"
STUB
chmod +x "$STUB_BIN/opencode"
export PATH="$STUB_BIN:$PATH"

run_output="$(bash "$REPO_ROOT/scripts/eval/run.sh" --skill=sut --case=missing 2>&1 || true)"
run_id="$(printf '%s\n' "$run_output" | sed -n 's/^\[eval-harness\] run_id=//p' | head -1)"
[[ -n "$run_id" ]] || { echo "FAIL: eval run produced no run_id" >&2; echo "$run_output" >&2; exit 1; }
results="$EVAL_STATE_DIR/runs/$run_id/results.json"
jq -e '.cases[0].checks[0].fix_proposal.kind == "missing_file" and .cases[0].checks[0].fix_proposal.auto_apply == true' "$results" >/dev/null \
  || { echo "FAIL: run did not generate an eligible missing-file proposal" >&2; cat "$results" >&2; exit 1; }

bash "$REPO_ROOT/scripts/eval/apply.sh" --run="$run_id" --yes --target-dir="$TARGET" > "$WORK/apply.out"
[[ -f "$TARGET/generated.txt" ]] || { echo "FAIL: apply did not create generated.txt" >&2; cat "$WORK/apply.out" >&2; exit 1; }

ln -s "$OUTSIDE" "$TARGET/escape"
mkdir -p "$EVAL_STATE_DIR/runs/symlink"
jq -n '{cases:[{checks:[{fix_proposal:{kind:"missing_file",confidence:"high",instruction:"create outside",patch_snippet:"escape/pwned.txt",auto_apply:true}}]}]}' > "$EVAL_STATE_DIR/runs/symlink/results.json"
bash "$REPO_ROOT/scripts/eval/apply.sh" --run=symlink --yes --target-dir="$TARGET" > "$WORK/symlink.out"
[[ ! -e "$OUTSIDE/pwned.txt" ]] || { echo "FAIL: symlink path escaped target-dir" >&2; exit 1; }

echo "PASS: generated missing-file proposal applies; symlink escape is refused"
