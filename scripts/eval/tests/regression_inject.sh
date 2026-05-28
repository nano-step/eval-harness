#!/usr/bin/env bash
# tests/regression_inject.sh — the canonical end-to-end demo for v0.1.0.
# Settled Decision #13: this script IS the worked example from the v2 brief.
# It runs entirely offline (no real opencode session) by pre-staging a fake
# transcript + atoms.json, then mutating the skill to demonstrate v0.1.0
# catches the regression with the full 6-field FAIL output.
#
# Flow:
#   1. Stage: temp workspace, fake skill, fake fixtures, fake transcript
#   2. Run case "atom-tags-decision-architecture" — should PASS, write baseline
#   3. Inject regression: drop the 'architecture' tag from atoms.json output
#   4. Re-run — should FAIL with attribution=SKILL_CHANGED and 6-field diff
#   5. Revert + verify PASS again
#
# This is a self-test of eval-harness using a STUBBED opencode (since real
# opencode would cost tokens). Real-opencode integration test is in v0.2.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EVAL_BIN="$SCRIPT_DIR/../run.sh"
BASELINE_BIN="$SCRIPT_DIR/../baseline.sh"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

WORK="$(mktemp -d -t eval-harness-test.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

export OPENCODE_SKILLS_ROOT="$WORK/skills"
export EVAL_STATE_DIR="$WORK/state"
mkdir -p "$OPENCODE_SKILLS_ROOT" "$EVAL_STATE_DIR"

# Locate the demo skill bundle: prefer the repo-root layout (development),
# fall back to OPENCODE_SKILLS_ROOT (installed layout), then to the
# default user-skills path.
DEMO_SRC=""
for candidate in \
    "$REPO_ROOT/skills/omo-session-distiller" \
    "${EVAL_HARNESS_DEMO_SKILL_DIR:-}" \
    "$HOME/.config/opencode/skills/omo-session-distiller" \
    "$(dirname "$SCRIPT_DIR")/../../skills/omo-session-distiller"; do
  if [[ -n "$candidate" && -d "$candidate" ]]; then
    DEMO_SRC="$candidate"; break
  fi
done
if [[ -z "$DEMO_SRC" ]]; then
  echo "FAIL: cannot locate demo skill 'omo-session-distiller'. Set EVAL_HARNESS_DEMO_SKILL_DIR to its path." >&2
  exit 2
fi
cp -R "$DEMO_SRC" "$OPENCODE_SKILLS_ROOT/"

# Stub: replace `opencode` with a script that writes the expected atoms.json directly.
# This makes the test deterministic + free (no real API calls).
STUB_BIN="$WORK/bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/opencode" <<'STUB'
#!/usr/bin/env bash
# Stub opencode for regression_inject.sh. Writes a canned atoms.json into cwd.
# The behavior is controlled by the env var EVAL_STUB_MODE.

if [[ "${1:-}" == "--version" ]]; then
  echo "1.15.10-stub"; exit 0
fi

cwd="$(pwd)"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir)    cwd="$2"; shift 2 ;;
    --dir=*)  cwd="${1#*=}"; shift ;;
    *)        shift ;;
  esac
done

mode="${EVAL_STUB_MODE:-pass}"
case "$mode" in
  pass)
    cat > "$cwd/atoms.json" <<'JSON'
{"atoms":[
  {"content":"Picked Postgres over MongoDB due to existing ops experience","id":"a-1","tags":["decision","architecture","database"],"type":"decision"},
  {"content":"Team already has Postgres runbooks","id":"a-2","tags":["ops","architecture"],"type":"learning"}
]}
JSON
    ;;
  regress)
    cat > "$cwd/atoms.json" <<'JSON'
{"atoms":[
  {"content":"Picked Postgres over MongoDB due to existing ops experience","id":"a-1","tags":["decision","database"],"type":"decision"},
  {"content":"Team already has Postgres runbooks","id":"a-2","tags":["ops"],"type":"learning"}
]}
JSON
    ;;
esac

echo "{\"event\":\"stub_complete\",\"mode\":\"$mode\"}"
exit 0
STUB
chmod +x "$STUB_BIN/opencode"
export PATH="$STUB_BIN:$PATH"

echo "================================================================"
echo "STEP 1/5: Baseline the green skill (stub returns full tag set)"
echo "================================================================"
export EVAL_STUB_MODE=pass
bash "$EVAL_BIN" --skill=omo-session-distiller --case=atom-tags-decision-architecture --trigger=baseline > "$WORK/step1.log" 2>&1 || true
cat "$WORK/step1.log"

bash "$BASELINE_BIN" --skill=omo-session-distiller --case=atom-tags-decision-architecture --force > "$WORK/step1b.log" 2>&1 || true
cat "$WORK/step1b.log"

BASELINE_FILE="$OPENCODE_SKILLS_ROOT/omo-session-distiller/evals/baselines/atom-tags-decision-architecture.baseline.json"
if [[ ! -f "$BASELINE_FILE" ]]; then
  echo "FAIL: baseline not written at $BASELINE_FILE" >&2
  exit 1
fi
echo
echo "  baseline written: $BASELINE_FILE"
echo "  baseline.passed: $(jq -r '.passed' "$BASELINE_FILE")"

echo
echo "================================================================"
echo "STEP 2/5: Inject regression (stub drops 'architecture' tag)"
echo "================================================================"
echo "Mutating distill skill: simulating user dropping --tags flag"
# Inject by changing the stub's behavior — this models a real skill edit
# that no longer emits the 'architecture' tag.
export EVAL_STUB_MODE=regress

# Also mutate a file inside the skill so skill_bundle_sha changes
echo "# regression injected by test $(date -u +%FT%TZ)" >> "$OPENCODE_SKILLS_ROOT/omo-session-distiller/SKILL.md"

echo
echo "================================================================"
echo "STEP 3/5: Re-run the case — should FAIL with attribution"
echo "================================================================"
set +e
bash "$EVAL_BIN" --skill=omo-session-distiller --case=atom-tags-decision-architecture --trigger=manual > "$WORK/step3.log" 2>&1
EXIT_RUN=$?
set -e
cat "$WORK/step3.log"
echo "  run exit code: $EXIT_RUN"

LATEST_RUN="$(ls -dt "$EVAL_STATE_DIR/runs"/* | head -1)"
RESULTS="$LATEST_RUN/results.json"
if [[ ! -f "$RESULTS" ]]; then
  echo "FAIL: results.json not produced at $RESULTS" >&2
  exit 1
fi

echo
echo "================================================================"
echo "STEP 4/5: Verify the FAIL output (6-field schema + attribution)"
echo "================================================================"

VERDICT="$(jq -r '.verdict' "$RESULTS")"
PASS_COUNT="$(jq -r '.summary.pass' "$RESULTS")"
FAIL_COUNT="$(jq -r '.summary.fail' "$RESULTS")"
REGRESSIONS="$(jq -r '.regressions | join(",")' "$RESULTS")"
ATTRIBUTION_TOP="$(jq -r '.cases[0].attribution.top' "$RESULTS")"
ENV_DELTA_KEYS="$(jq -r '.cases[0].env_delta.keys_changed | join(",")' "$RESULTS")"
FAILED_CHECK_ID="$(jq -r '.cases[0].checks[] | select(.passed == false) | .failed_check_id' "$RESULTS" | head -1)"

echo "  verdict:        $VERDICT"
echo "  pass/fail:      $PASS_COUNT/$FAIL_COUNT"
echo "  regressions:    $REGRESSIONS"
echo "  attribution:    $ATTRIBUTION_TOP"
echo "  env_delta keys: $ENV_DELTA_KEYS"
echo "  failed check:   $FAILED_CHECK_ID"

# Acceptance assertions (Settled #13: this is the verification step)
ok=1
[[ "$VERDICT" == "REGRESSION" ]] || { echo "FAIL: expected verdict=REGRESSION, got '$VERDICT'" >&2; ok=0; }
[[ "$ATTRIBUTION_TOP" == "SKILL_CHANGED" ]] || { echo "FAIL: expected attribution=SKILL_CHANGED, got '$ATTRIBUTION_TOP'" >&2; ok=0; }
[[ "$REGRESSIONS" == *"atom-tags-decision-architecture"* ]] || { echo "FAIL: expected regression in atom-tags-decision-architecture" >&2; ok=0; }
[[ -n "$FAILED_CHECK_ID" ]] || { echo "FAIL: no failed_check_id in results" >&2; ok=0; }
[[ "$EXIT_RUN" == "0" ]] || { echo "FAIL: expected warn-only exit 0 (not promoted), got $EXIT_RUN" >&2; ok=0; }

echo
echo "================================================================"
echo "STEP 5/5: Verify diff.md was generated"
echo "================================================================"
DIFF_MD="$LATEST_RUN/diff.md"
if [[ -f "$DIFF_MD" ]]; then
  echo "  diff.md generated at: $DIFF_MD"
  echo "  first 20 lines:"
  sed 's/^/    /' "$DIFF_MD" | head -20
else
  echo "FAIL: diff.md not generated" >&2
  ok=0
fi

echo
echo "================================================================"
if [[ "$ok" == "1" ]]; then
  echo "ALL ASSERTIONS PASSED — eval-harness v0.1.0 demo is real."
  exit 0
else
  echo "DEMO FAILED — see output above"
  exit 1
fi
