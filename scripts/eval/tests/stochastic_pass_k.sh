#!/usr/bin/env bash
# Regression test for #21: stochastic mode runs a case N times and passes iff at least
# pass_threshold samples pass. Stub passes 4 of 5 samples -> threshold 4 PASS, threshold 5 FAIL.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
RUN="$REPO_ROOT/scripts/eval/run.sh"

WORK="$(mktemp -d -t eval-harness-stoch.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
export OPENCODE_SKILLS_ROOT="$WORK/skills"
export EVAL_STATE_DIR="$WORK/state"
export EVAL_SKIP_AUTH_CHECK=1
CASES="$OPENCODE_SKILLS_ROOT/test-skill/evals/cases"
mkdir -p "$CASES"

mk_case() {  # mk_case <id> <pass_threshold>
  cat > "$CASES/$1.yaml" <<YAML
schema_version: 2
id: $1
mode: stochastic
samples: 5
pass_threshold: $2
temperature: 0.7
prompt: "make out.txt"
checks:
  - kind: file_exists
    path: out.txt
YAML
}
mk_case c4 4
mk_case c5 5

# Stub opencode: creates out.txt for the first 4 RUN invocations (not --version), skips the 5th.
STUB_BIN="$WORK/bin"; mkdir -p "$STUB_BIN"
export STOCH_COUNTER="$WORK/counter"
cat > "$STUB_BIN/opencode" <<'STUB'
#!/usr/bin/env bash
[[ "${1:-}" == "--version" ]] && { echo "1.15.10-stub"; exit 0; }
cwd="$(pwd)"
while [[ $# -gt 0 ]]; do case "$1" in --dir) cwd="$2"; shift 2;; --dir=*) cwd="${1#*=}"; shift;; *) shift;; esac; done
n="$(cat "$STOCH_COUNTER" 2>/dev/null || echo 0)"; n=$((n+1)); echo "$n" > "$STOCH_COUNTER"
[[ "$n" -le 4 ]] && : > "$cwd/out.txt"
echo "{}"
exit 0
STUB
chmod +x "$STUB_BIN/opencode"
export PATH="$STUB_BIN:$PATH"

run_case_passed() {  # echoes the case pass boolean for a fresh exact run
  : > "$STOCH_COUNTER"
  local run_output run_id latest
  run_output="$(bash "$RUN" --skill=test-skill --case="$1" 2>&1 || true)"
  printf '%s\n' "$run_output" > "$WORK/last_run.log"
  run_id="$(printf '%s\n' "$run_output" | sed -n 's/^\[eval-harness\] run_id=//p' | head -1)"
  latest="$EVAL_STATE_DIR/runs/$run_id"
  if [[ -z "$run_id" || ! -f "$latest/results.json" ]]; then cat "$WORK/last_run.log" >&2; echo "FAIL: run did not produce results.json" >&2; return 1; fi
  printf '%s' "$run_id" > "$WORK/latest_run_id"
  jq -r '.cases[0].passed' "$latest/results.json"
  jq -c '.cases[0].checks[0]' "$latest/results.json" > "$WORK/last_check.json"
}

# threshold 4: 4/5 pass -> case PASSES
p="$(run_case_passed c4)"
[[ "$p" == "true" ]] || { echo "FAIL: threshold 4 with 4/5 passing should PASS, got $p" >&2; cat "$WORK/last_check.json" >&2; exit 1; }
samp="$(jq -r '.actual' "$WORK/last_check.json")"
[[ "$samp" == *"4/5 samples passed"* ]] || { echo "FAIL: expected '4/5 samples passed', got '$samp'" >&2; exit 1; }
# (#EV-W) The stochastic object carries a Wilson interval; for 4/5 it is ~[0.376, 0.964].
latest="$EVAL_STATE_DIR/runs/$(cat "$WORK/latest_run_id")"; wl="$(jq -r '.cases[0].stochastic.wilson.lower' "$latest/results.json" 2>/dev/null || echo "")"
awk -v x="$wl" 'BEGIN{exit !(x+0 > 0.37 && x+0 < 0.39)}' || { echo "FAIL: 4/5 Wilson lower expected ~0.376, got '$wl'" >&2; exit 1; }

grading_rel="$(jq -r '.cases[0].grading_manifest.path' "$latest/results.json")"
if bash "$REPO_ROOT/scripts/eval/grade.sh" --manifest="$latest/$grading_rel" >"$WORK/stochastic-grade.json" 2>&1; then
  grade_rc=0
else
  grade_rc=$?
fi
[[ "$grade_rc" -eq 13 && "$(jq -r '.status' "$WORK/stochastic-grade.json")" == "ERROR" ]] || {
  echo "FAIL: stochastic aggregate was replayed as a deterministic artifact (exit=$grade_rc)" >&2
  cat "$WORK/stochastic-grade.json" >&2
  exit 1
}

manifest="$latest/$grading_rel"
jq '.mode="deterministic"' "$manifest" > "$WORK/tampered-mode.json"
mv "$WORK/tampered-mode.json" "$manifest"
if bash "$REPO_ROOT/scripts/eval/grade.sh" --manifest="$manifest" >"$WORK/stochastic-mode-tamper.json" 2>&1; then
  tamper_rc=0
else
  tamper_rc=$?
fi
[[ "$tamper_rc" -eq 13 && "$(jq -r '.status' "$WORK/stochastic-mode-tamper.json")" == "ERROR" ]] || {
  echo "FAIL: manifest mode override bypassed stochastic-case replay restriction (exit=$tamper_rc)" >&2
  cat "$WORK/stochastic-mode-tamper.json" >&2
  exit 1
}
# threshold 5: 4/5 pass -> case FAILS
p="$(run_case_passed c5)"
[[ "$p" == "false" ]] || { echo "FAIL: threshold 5 with 4/5 passing should FAIL, got $p" >&2; cat "$WORK/last_check.json" >&2; exit 1; }

# Non-numeric pass_threshold must NOT crash the run (set -u arithmetic hazard); it must
# surface as a per-case harness_error and the run must still complete.
cat > "$CASES/cbad.yaml" <<'YAML'
schema_version: 2
id: cbad
mode: stochastic
samples: 5
pass_threshold: oops
prompt: "x"
checks:
  - kind: file_exists
    path: out.txt
YAML
: > "$STOCH_COUNTER"
set +e
bash "$RUN" --skill=test-skill --case=cbad >"$WORK/bad.log" 2>&1
rc=$?
set -e
run_id="$(sed -n 's/^\[eval-harness\] run_id=//p' "$WORK/bad.log" | head -1)"
latest="$EVAL_STATE_DIR/runs/$run_id"
err="$(jq -r '.cases[0].checks[0].error // false' "$latest/results.json" 2>/dev/null)"
kind="$(jq -r '.cases[0].checks[0].kind' "$latest/results.json" 2>/dev/null)"
[[ "$err" == "true" && "$kind" == "harness_error" ]] || { echo "FAIL: non-numeric threshold should yield harness_error, got kind=$kind err=$err (rc=$rc)" >&2; cat "$WORK/bad.log" >&2; exit 1; }
grep -qi "unbound variable" "$WORK/bad.log" && { echo "FAIL: run crashed with unbound variable on non-numeric threshold" >&2; exit 1; }

# (#EV-W) Golden-value Wilson check via lib/stats.sh directly.
source "$REPO_ROOT/scripts/eval/lib/stats.sh"
g="$(wilson_interval 8 10 1.96)"
gl="$(echo "$g" | jq -r '.lower')"; gu="$(echo "$g" | jq -r '.upper')"
awk -v l="$gl" -v u="$gu" 'BEGIN{exit !(l>0.489 && l<0.491 && u>0.942 && u<0.944)}' || { echo "FAIL: wilson(8,10,1.96) golden expected ~[0.490,0.943], got [$gl,$gu]" >&2; exit 1; }
# edges stay in [0,1]
for pair in "5 5" "0 5" "1 1" "0 0"; do
  set -- $pair
  lo="$(wilson_interval "$1" "$2" | jq -r '.lower')"; up="$(wilson_interval "$1" "$2" | jq -r '.upper')"
  awk -v l="$lo" -v u="$up" 'BEGIN{exit !(l>=0 && l<=1 && u>=0 && u<=1)}' || { echo "FAIL: wilson($pair) out of [0,1]: [$lo,$up]" >&2; exit 1; }
done

# (#EV-W) ci_gate mode: a high required lower-bound FAILs a 4/5 case (wilson_lower~0.376<0.6)
# even though raw 4>=pass_threshold would pass.
cat > "$CASES/cgate.yaml" <<'YAML'
schema_version: 2
id: cgate
mode: stochastic
samples: 5
pass_threshold: 4
ci_gate: lower_bound
ci_required_rate: 0.6
prompt: "make out.txt"
checks:
  - kind: file_exists
    path: out.txt
YAML
p="$(run_case_passed cgate)"
[[ "$p" == "false" ]] || { echo "FAIL: ci_gate lower_bound 0.6 should FAIL a 4/5 case (wilson_lower~0.376), got $p" >&2; cat "$WORK/last_check.json" >&2; exit 1; }

echo "PASS: stochastic pass@k — threshold gating, non-numeric guard, Wilson golden+edges, ci_gate lower-bound"
exit 0
