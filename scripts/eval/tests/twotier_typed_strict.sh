#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
WORK="$(mktemp -d -t eval-harness-2tier-typed.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
export OPENCODE_SKILLS_ROOT="$WORK/skills"
export EVAL_STATE_DIR="$WORK/state"
export EVAL_SKIP_AUTH_CHECK=1
mkdir -p "$OPENCODE_SKILLS_ROOT/sut/evals/cases" "$WORK/bin"

cat > "$OPENCODE_SKILLS_ROOT/sut/evals/cases/pending.yaml" <<'YAML'
schema_version: 2
id: pending
prompt: noop
eval_type: capability
checks:
  - kind: human_review
    file: review.json
YAML
cat > "$OPENCODE_SKILLS_ROOT/sut/evals/cases/unavailable.yaml" <<'YAML'
schema_version: 2
id: unavailable
prompt: noop
eval_type: capability
checks:
  - kind: metric_score
    file: score.json
    path: .score
    minimum: 0.5
YAML
cat > "$OPENCODE_SKILLS_ROOT/sut/evals/cases/error.yaml" <<'YAML'
schema_version: 2
id: error
prompt: noop
eval_type: capability
checks: []
YAML

cat > "$WORK/bin/opencode" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then echo "1.15.10-stub"; exit 0; fi
printf 'run\n' >> "$EVAL_RUN_MARKER"
echo "{}"
STUB
chmod +x "$WORK/bin/opencode"
export PATH="$WORK/bin:$PATH"
export EVAL_RUN_MARKER="$WORK/runs"

assert_typed() {
  local case_id="$1" expected_status="$2" expected_rc="$3" output rc latest status runs
  : > "$EVAL_RUN_MARKER"
  if output="$(bash "$REPO_ROOT/scripts/eval/run.sh" --skill=sut --case="$case_id" --mode=2tier --strict 2>&1)"; then
    rc=0
  else
    rc=$?
  fi
  [[ "$rc" -eq "$expected_rc" ]] || { echo "FAIL: $case_id exit=$rc, expected $expected_rc" >&2; echo "$output" >&2; exit 1; }
  latest="$(ls -dt "$EVAL_STATE_DIR/runs"/* | head -1)"
  status="$(jq -r '.cases[0].status' "$latest/results.json")"
  [[ "$status" == "$expected_status" ]] || { echo "FAIL: $case_id status=$status, expected $expected_status" >&2; cat "$latest/results.json" >&2; exit 1; }
  runs="$(wc -l < "$EVAL_RUN_MARKER" | tr -d ' ')"
  [[ "$runs" == 1 ]] || { echo "FAIL: $case_id escalated a typed non-FAIL result; runner calls=$runs" >&2; echo "$output" >&2; exit 1; }
}

assert_typed pending NEEDS_REVIEW 15
assert_typed unavailable INDETERMINATE 16
assert_typed error ERROR 13

echo "PASS: two-tier mode preserves strict NEEDS_REVIEW, INDETERMINATE, and ERROR outcomes without full escalation"
