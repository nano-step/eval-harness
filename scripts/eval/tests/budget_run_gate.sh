#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
WORK="$(mktemp -d -t eval-harness-budget.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

export EVAL_STATE_DIR="$WORK/state"
export OPENCODE_SKILLS_ROOT="$WORK/skills"
export EVAL_SKIP_AUTH_CHECK=1
export EVAL_BUDGET_USD=1.00
export EVAL_BUDGET_TZ=UTC
mkdir -p "$OPENCODE_SKILLS_ROOT/sut/evals/cases" "$WORK/bin"
cat > "$OPENCODE_SKILLS_ROOT/sut/evals/cases/c1.yaml" <<'YAML'
schema_version: 2
id: c1
eval_type: capability
prompt: "write out.txt"
checks:
  - kind: file_exists
    path: out.txt
YAML
cat > "$WORK/bin/opencode" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then echo "1.15.10-stub"; exit 0; fi
echo invoked >> "$EVAL_RUN_MARKER"
echo "{}"
STUB
chmod +x "$WORK/bin/opencode"
export PATH="$WORK/bin:$PATH"
export EVAL_RUN_MARKER="$WORK/runner-invoked"

source "$REPO_ROOT/scripts/eval/lib/budget.sh"
budget_append old-unmeasured null test/model
if bash "$REPO_ROOT/scripts/eval/run.sh" --skill=sut >"$WORK/run.out" 2>&1; then
  echo "FAIL: run proceeded with unknown ledger spend" >&2
  cat "$WORK/run.out" >&2
  exit 1
else
  rc=$?
fi
[[ "$rc" -eq 13 ]] || { echo "FAIL: budget refusal exit=$rc, expected 13" >&2; cat "$WORK/run.out" >&2; exit 1; }
[[ ! -e "$EVAL_RUN_MARKER" ]] || { echo "FAIL: runner started after the budget gate refused the run" >&2; exit 1; }
grep -q "budget blocked" "$WORK/run.out" || { echo "FAIL: budget refusal message missing" >&2; cat "$WORK/run.out" >&2; exit 1; }

echo "PASS: unknown ledger cost blocks run before the execution runner starts"
