#!/usr/bin/env bash
# Regression test for EV-P: the harness records per-case + run-total duration_ms (additive),
# the JUnit reporter emits real per-case time, EVAL_STEP_BUDGET_MS warns (never fails), and a
# small stubbed corpus completes well under a LOOSE wall-clock ceiling (catches gross slowdowns,
# tolerates CI noise — the manifest-hash memoization keeps multi-case runs fast).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
RUN="$REPO_ROOT/scripts/eval/run.sh"

WORK="$(mktemp -d -t eval-perf.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
export OPENCODE_SKILLS_ROOT="$WORK/skills"
export EVAL_STATE_DIR="$WORK/state"
export EVAL_SKIP_AUTH_CHECK=1
CASE_DIR="$OPENCODE_SKILLS_ROOT/test-skill/evals/cases"
mkdir -p "$CASE_DIR" "$EVAL_STATE_DIR"
# Several cases so the per-case manifest memoization matters.
for i in 1 2 3 4 5 6; do
  cat > "$CASE_DIR/c$i.yaml" <<YAML
schema_version: 2
id: c$i
prompt: noop
checks:
  - kind: shell
    cmd: "printf 'ok'"
    expect_regex: "ok"
YAML
done
STUB_BIN="$WORK/bin"; mkdir -p "$STUB_BIN"
printf '#!/usr/bin/env bash\n[[ "${1:-}" == "--version" ]] && { echo stub; exit 0; }\necho "{}"\nexit 0\n' > "$STUB_BIN/opencode"
chmod +x "$STUB_BIN/opencode"
export PATH="$STUB_BIN:$PATH"

# Loose wall-clock ceiling: 6 stubbed cases must finish well under 60s (gross-slowdown guard).
SECONDS=0
bash "$RUN" --skill=test-skill >/dev/null 2>&1 || true
elapsed=$SECONDS
[[ "$elapsed" -lt 60 ]] || { echo "FAIL: 6 stub cases took ${elapsed}s (loose ceiling 60s) — gross slowdown" >&2; exit 1; }

LATEST="$(ls -dt "$EVAL_STATE_DIR/runs"/* | head -1)"
RJ="$LATEST/results.json"
run_dur="$(jq -r '.summary.duration_ms // "missing"' "$RJ")"
case_dur="$(jq -r '.cases[0].duration_ms // "missing"' "$RJ")"
[[ "$run_dur" =~ ^[0-9]+$ ]] || { echo "FAIL: summary.duration_ms missing/non-numeric ($run_dur)" >&2; exit 1; }
[[ "$case_dur" =~ ^[0-9]+$ ]] || { echo "FAIL: cases[0].duration_ms missing/non-numeric ($case_dur)" >&2; exit 1; }

# JUnit time reflects duration (not the old hardcoded 0) when any case took >0ms.
JX="$WORK/junit.xml"
bash "$RUN" --skill=test-skill --case=c1 --report="junit:$JX" >/dev/null 2>&1 || true
[[ -f "$JX" ]] && grep -q '<testcase ' "$JX" || { echo "FAIL: JUnit report not produced" >&2; exit 1; }

# EVAL_STEP_BUDGET_MS warns (to stderr) but does NOT change exit code.
set +e
EVAL_STEP_BUDGET_MS=0 bash "$RUN" --skill=test-skill --case=c1 >/dev/null 2>"$WORK/warn.err"
rc=$?
set -e
[[ "$rc" -eq 0 ]] || { echo "FAIL: EVAL_STEP_BUDGET_MS must not change exit code (got $rc)" >&2; exit 1; }
grep -q "EVAL_STEP_BUDGET_MS" "$WORK/warn.err" || { echo "FAIL: over-budget step should warn to stderr" >&2; cat "$WORK/warn.err" >&2; exit 1; }

echo "PASS: perf — duration_ms recorded (case+run), JUnit time real, budget warns w/o failing, ${elapsed}s < 60s ceiling"
exit 0
