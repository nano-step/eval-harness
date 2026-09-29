#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
RUN="$REPO_ROOT/scripts/eval/run.sh"
WORK="$(mktemp -d -t eval-harness-baseline-provenance.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
export OPENCODE_SKILLS_ROOT="$WORK/skills"
export EVAL_STATE_DIR="$WORK/state"
export EVAL_SKIP_AUTH_CHECK=1
export EVAL_BUDGET_USD=""
CASE_DIR="$OPENCODE_SKILLS_ROOT/provenance-skill/evals/cases"
BASELINE_DIR="$OPENCODE_SKILLS_ROOT/provenance-skill/evals/baselines"
mkdir -p "$CASE_DIR" "$BASELINE_DIR" "$WORK/bin"

cat > "$CASE_DIR/pass.yaml" <<'YAML'
schema_version: 2
id: pass
prompt: create generated.txt
checks:
  - kind: file_exists
    path: generated.txt
YAML
cat > "$CASE_DIR/fail.yaml" <<'YAML'
schema_version: 2
id: fail
prompt: no output
checks:
  - kind: file_exists
    path: absent.txt
YAML
cat > "$WORK/bin/opencode" <<'STUB'
#!/usr/bin/env bash
[[ "${1:-}" == "--version" ]] && { echo "1.15.10-stub"; exit 0; }
cwd="$(pwd)"
while [[ $# -gt 0 ]]; do
  case "$1" in --dir) cwd="$2"; shift 2 ;; --dir=*) cwd="${1#*=}"; shift ;; *) shift ;; esac
done
touch "$cwd/generated.txt"
echo "{}"
exit 0
STUB
chmod +x "$WORK/bin/opencode"
export PATH="$WORK/bin:$PATH"

run_id_from_output() { printf '%s\n' "$1" | sed -n 's/^\[eval-harness\] run_id=//p' | head -1; }
run_case() {
  local case_id="$1" output run_id
  output="$(bash "$RUN" --skill=provenance-skill --case="$case_id" --trigger=provenance 2>&1 || true)"
  printf '%s\n' "$output" > "$WORK/$case_id.run.log"
  run_id="$(run_id_from_output "$output")"
  [[ -n "$run_id" && -f "$EVAL_STATE_DIR/runs/$run_id/results.json" ]] || { cat "$WORK/$case_id.run.log" >&2; echo "FAIL: $case_id run has no result" >&2; return 1; }
  printf '%s\n' "$run_id"
}

# Baseline creation records the exact run which supplied the accepted case.
baseline_output="$(bash "$RUN" baseline --skill=provenance-skill --case=pass --portable 2>&1)"
baseline_run_id="$(run_id_from_output "$baseline_output")"
baseline="$BASELINE_DIR/pass.baseline.json"
[[ -n "$baseline_run_id" && -f "$baseline" ]] || { printf '%s\n' "$baseline_output" >&2; echo "FAIL: baseline command did not write a baseline" >&2; exit 1; }
[[ "$(jq -r '.case_id' "$baseline")" == "pass" && "$(jq -r '.source_run_id' "$baseline")" == "$baseline_run_id" ]] || { echo "FAIL: baseline identity/provenance mismatch" >&2; exit 1; }

# Put a later nonmatching failed case in run history. Default accept must select the newest matching case, not the globally newest run.
pass_run_id="$(run_case pass)"
fail_run_id="$(run_case fail)"
[[ "$(jq -r '.cases[0].status' "$EVAL_STATE_DIR/runs/$fail_run_id/results.json")" == "FAIL" ]] || { echo "FAIL: fixture did not produce a failing case" >&2; exit 1; }
bash "$RUN" accept --skill=provenance-skill --case=pass --bless-env --yes > "$WORK/accept.log" 2>&1
[[ "$(jq -r '.source_run_id' "$baseline")" == "$pass_run_id" ]] || { echo "FAIL: accept did not record the newest matching run" >&2; cat "$WORK/accept.log" >&2; exit 1; }

# An explicit unrelated run must not be accepted or mutate the valid baseline.
cp "$baseline" "$WORK/baseline.before.json"
set +e
bash "$RUN" accept --skill=provenance-skill --case=pass --run="$fail_run_id" --bless-env --yes > "$WORK/wrong-run.log" 2>&1
wrong_run_rc=$?
set -e
[[ "$wrong_run_rc" -eq 2 ]] && cmp -s "$baseline" "$WORK/baseline.before.json" || { echo "FAIL: unrelated run was accepted or baseline changed" >&2; cat "$WORK/wrong-run.log" >&2; exit 1; }

# A real FAIL is never accepted as a baseline.
set +e
bash "$RUN" accept --skill=provenance-skill --case=fail --run="$fail_run_id" --bless-env --yes > "$WORK/fail-accept.log" 2>&1
fail_accept_rc=$?
set -e
[[ "$fail_accept_rc" -eq 14 && ! -f "$BASELINE_DIR/fail.baseline.json" ]] || { echo "FAIL: failed case was accepted or returned wrong status" >&2; cat "$WORK/fail-accept.log" >&2; exit 1; }

# Rebaseline also refreshes provenance from its own exact run.
rebaseline_output="$(bash "$RUN" rebaseline --skill=provenance-skill --case=pass 2>&1)"
rebaseline_run_id="$(run_id_from_output "$rebaseline_output")"
[[ -n "$rebaseline_run_id" && "$(jq -r '.source_run_id' "$baseline")" == "$rebaseline_run_id" ]] || { echo "FAIL: rebaseline source run is missing or stale" >&2; printf '%s\n' "$rebaseline_output" >&2; exit 1; }

echo "PASS: baseline, accept, and rebaseline retain exact source runs; acceptance filters by case and rejects non-PASS evidence"
