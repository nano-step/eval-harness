#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

WORK="$(mktemp -d -t eval-harness-2t-agg.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

export OPENCODE_SKILLS_ROOT="$WORK/skills"
export EVAL_STATE_DIR="$WORK/state"
export EVAL_SKIP_AUTH_CHECK=1
mkdir -p "$OPENCODE_SKILLS_ROOT/twoskill/evals/cases"

cat > "$OPENCODE_SKILLS_ROOT/twoskill/evals/cases/will-fail.yaml" <<YAML
schema_version: 2
id: will-fail
mode: deterministic
skill_under_test: twoskill
skills_loaded: [twoskill]
prompt: noop
budget: {max_tokens: 100, max_seconds: 10}
checks:
  - kind: file_exists
    path: this-will-never-exist
YAML

cat > "$OPENCODE_SKILLS_ROOT/twoskill/evals/cases/also-fail.yaml" <<YAML
schema_version: 2
id: also-fail
mode: deterministic
skill_under_test: twoskill
skills_loaded: [twoskill]
prompt: noop
budget: {max_tokens: 100, max_seconds: 10}
checks:
  - kind: file_exists
    path: also-never-exists
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

set +e
bash "$REPO_ROOT/scripts/eval/run.sh" --skill=twoskill --mode=2tier > "$WORK/out.log" 2>&1
EXIT_RC=$?
set -e

AGG_RUN="$(ls -dt "$EVAL_STATE_DIR/runs"/2tier-* 2>/dev/null | head -1)"
if [[ -z "$AGG_RUN" || ! -f "$AGG_RUN/results.json" ]]; then
  echo "FAIL: aggregated results.json not produced under $EVAL_STATE_DIR/runs/2tier-*" >&2
  cat "$WORK/out.log" >&2
  exit 1
fi

MODE="$(jq -r '.mode' "$AGG_RUN/results.json")"
[[ "$MODE" == "2tier" ]] || { echo "FAIL: mode=$MODE expected 2tier" >&2; exit 1; }

VERDICT="$(jq -r '.verdict' "$AGG_RUN/results.json")"
ESCALATED="$(jq -r '.summary.full_escalated' "$AGG_RUN/results.json")"
[[ "$ESCALATED" == "2" ]] || { echo "FAIL: full_escalated=$ESCALATED expected 2 (both smoke-failed cases)" >&2; jq . "$AGG_RUN/results.json" >&2; exit 1; }

FULL_FAIL="$(jq -r '.summary.full_fail' "$AGG_RUN/results.json")"
[[ "$FULL_FAIL" == "2" ]] || { echo "FAIL: full_fail=$FULL_FAIL expected 2" >&2; exit 1; }

CONTRIBUTING="$(jq -r '.contributing_run_ids | length' "$AGG_RUN/results.json")"
[[ "$CONTRIBUTING" -ge "3" ]] || { echo "FAIL: contributing_run_ids should be >=3 (smoke + 2 escalations), got $CONTRIBUTING" >&2; exit 1; }

[[ "$EXIT_RC" == "0" ]] || { echo "FAIL: no baselines + both fail -> verdict FAIL -> exit 0 expected, got $EXIT_RC" >&2; exit 1; }

echo "PASS: 2tier aggregation — 2 cases escalated, both surface in full_cases, contributing_run_ids tracks all 3 sub-runs, exit code 0 when no baseline to compare"
exit 0
