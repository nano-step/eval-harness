#!/usr/bin/env bash
# tests/ab_compare.sh — end-to-end test for scripts/eval/ab.sh
#
# Creates two stub skills under a temp OPENCODE_SKILLS_ROOT:
#   base-skill:      stub opencode CREATES the expected file  -> case PASSES
#   candidate-skill: stub opencode does NOT create the file   -> case FAILS
#
# Verifies:
#   1. ab.sh exits 12 for a base-PASS/candidate-FAIL regression
#   2. The report retains typed case status and identifies the regression
#   3. The comparison result is selected from this invocation’s exact run directory
#   4. Independent base/candidate model overrides reach both per-side manifests

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
AB_BIN="$REPO_ROOT/scripts/eval/ab.sh"

WORK="$(mktemp -d -t eval-harness-ab.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

export OPENCODE_SKILLS_ROOT="$WORK/skills"
export EVAL_STATE_DIR="$WORK/state"
export EVAL_SKIP_AUTH_CHECK=1 # Fixture runners are local stubs; no provider credential is needed.
export EVAL_BUDGET_USD="" # fake model writes no token-usage metadata
mkdir -p "$OPENCODE_SKILLS_ROOT" "$EVAL_STATE_DIR/runs"

# ---------------------------------------------------------------------------
# 1. Materialise two stub skills, each with one identical case.
#    The case uses a file_exists check on "output.txt".
#    base-skill's opencode stub creates output.txt  -> PASS
#    cand-skill's opencode stub does NOT create it  -> FAIL
# ---------------------------------------------------------------------------

CASE_ID="check-output-file"

for skill in base-skill cand-skill; do
  CASES_DIR="$OPENCODE_SKILLS_ROOT/$skill/evals/cases"
  mkdir -p "$CASES_DIR"

  cat > "$CASES_DIR/$CASE_ID.yaml" <<YAML
schema_version: 2
id: $CASE_ID
mode: deterministic
skill_under_test: $skill
skills_loaded: [$skill]
description: "Check that the skill creates output.txt"
prompt: |
  Create a file called output.txt with any content.
budget: {max_tokens: 1000, max_seconds: 60}
checks:
  - kind: file_exists
    path: output.txt
YAML
done

# ---------------------------------------------------------------------------
# 2. Stub opencode: behaviour is controlled by EVAL_AB_STUB_SKILL env var.
#    "base-skill"  -> creates output.txt in cwd  (PASS)
#    "cand-skill"  -> does nothing               (FAIL)
# ---------------------------------------------------------------------------
STUB_BIN="$WORK/bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/opencode" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then echo "1.15.10-stub"; exit 0; fi

# Parse --dir / --dir=value from args to find workdir
cwd="$(pwd)"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir)    cwd="$2"; shift 2 ;;
    --dir=*)  cwd="${1#*=}"; shift ;;
    *)        shift ;;
  esac
done

skill="${EVAL_AB_STUB_SKILL:-}"

if [[ "$skill" == "base-skill" ]]; then
  # Base skill: create the expected file so the check passes.
  printf 'base output\n' > "$cwd/output.txt"
fi
# Candidate skill: do nothing — output.txt is absent -> check fails.

echo "{}"
exit 0
STUB
chmod +x "$STUB_BIN/opencode"

# ---------------------------------------------------------------------------
# 3. Wrapper script that sets EVAL_AB_STUB_SKILL from --skill= and then
#    calls the real stub. We place this as a wrapper so run.sh can call it.
# ---------------------------------------------------------------------------
cat > "$STUB_BIN/opencode-dispatch" <<'WRAPPER'
#!/usr/bin/env bash
# Extracts --skill from the EVAL_SKILL_UNDER_TEST env var set by run.sh,
# or parse it from the opencode invocation args passed by spawn.sh.
# The real dispatch is through EVAL_AB_STUB_SKILL which the stub reads.
exec "$@"
WRAPPER
chmod +x "$STUB_BIN/opencode-dispatch"

# run.sh calls `opencode` directly from PATH with the prompt and --dir.
# We need the stub to know which skill is being run so it can behave differently.
# The cleanest approach: replace `opencode` with a dispatcher that reads
# the SKILL being evaluated from the run.sh environment.
# run.sh exports SKILL as the local var; it's not exported.
# Instead, we use a second level: create per-skill opencode wrappers that set
# EVAL_AB_STUB_SKILL before exec-ing the real stub.
#
# We do this by overriding opencode in per-skill fixture dirs and
# having the case set it up. But the simpler path:
# run.sh spawns opencode with the workdir; we can detect which skill we are
# by checking for a sentinel file in the workdir that we place per-skill.
#
# Simplest deterministic approach: each skill's case places a fixture file
# with the skill name in it, and the stub reads that file to decide behavior.

# Place a sentinel fixture in each skill's evals/fixtures dir.
for skill in base-skill cand-skill; do
  mkdir -p "$OPENCODE_SKILLS_ROOT/$skill/evals/fixtures"
  printf '%s\n' "$skill" > "$OPENCODE_SKILLS_ROOT/$skill/evals/fixtures/skill-name.txt"
done

# Update each case YAML to include the skill-name.txt fixture so the stub can
# detect which skill it's running under.
for skill in base-skill cand-skill; do
  CASE_FILE="$OPENCODE_SKILLS_ROOT/$skill/evals/cases/$CASE_ID.yaml"
  cat > "$CASE_FILE" <<YAML
schema_version: 2
id: $CASE_ID
mode: deterministic
skill_under_test: $skill
skills_loaded: [$skill]
description: "Check that the skill creates output.txt"
setup:
  fixtures:
    "skill-name.txt": fixtures/skill-name.txt
prompt: |
  Create a file called output.txt with any content.
budget: {max_tokens: 1000, max_seconds: 60}
checks:
  - kind: file_exists
    path: output.txt
YAML
done

# Update the stub to read skill-name.txt from cwd instead of env var.
cat > "$STUB_BIN/opencode" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then echo "1.15.10-stub"; exit 0; fi

cwd="$(pwd)"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir)    cwd="$2"; shift 2 ;;
    --dir=*)  cwd="${1#*=}"; shift ;;
    *)        shift ;;
  esac
done

skill=""
if [[ -f "$cwd/skill-name.txt" ]]; then
  skill="$(cat "$cwd/skill-name.txt")"
fi

if [[ "$skill" == "base-skill" ]]; then
  # Base skill: create the expected file -> PASS
  printf 'base output\n' > "$cwd/output.txt"
fi
# cand-skill: do nothing -> output.txt absent -> FAIL

echo "{}"
exit 0
STUB
chmod +x "$STUB_BIN/opencode"

export PATH="$STUB_BIN:$PATH"

# ---------------------------------------------------------------------------
# 4. Run ab.sh and capture output + exit code.
# ---------------------------------------------------------------------------
AB_OUT="$WORK/ab.log"
ab_exit=0
bash "$AB_BIN" --base=base-skill --candidate=cand-skill --base-model=vendor/base-model --candidate-model=vendor/candidate-model \
  > "$AB_OUT" 2>&1 || ab_exit=$?

echo "=== ab.sh output ==="
cat "$AB_OUT"
echo "=== exit code: $ab_exit ==="

# ---------------------------------------------------------------------------
# 5. Assertions.
# ---------------------------------------------------------------------------
ok=1

# 5a. Exit code must be 12.
if [[ "$ab_exit" -ne 12 ]]; then
  printf 'FAIL: expected exit code 12 (regression), got %d\n' "$ab_exit" >&2
  ok=0
fi

# 5b. stdout must mention REGRESSION for the failing case.
if ! grep -qi "REGRESSION" "$AB_OUT"; then
  echo "FAIL: expected 'REGRESSION' in ab.sh output" >&2
  ok=0
fi

# 5c. The machine-readable results.json must exist and mark the case regressed.
AB_RESULTS="$(sed -n 's/^\[ab\] results dir: //p' "$AB_OUT" | head -1)"
if [[ -z "$AB_RESULTS" ]] || [[ ! -f "$AB_RESULTS/results.json" ]]; then
  echo "FAIL: ab results.json not found under $EVAL_STATE_DIR/runs/ab-*/" >&2
  ok=0
else
  regressed_count="$(jq '[.cases[] | select(.regressed == true)] | length' "$AB_RESULTS/results.json" 2>/dev/null || echo 0)"
  if [[ "$regressed_count" -lt 1 ]]; then
    echo "FAIL: expected at least 1 regressed case in results.json, got $regressed_count" >&2
    cat "$AB_RESULTS/results.json" >&2
    ok=0
  fi

  verdict="$(jq -r '.verdict' "$AB_RESULTS/results.json" 2>/dev/null || echo '')"
  if [[ "$verdict" != "REGRESSION" ]]; then
    printf 'FAIL: expected verdict=REGRESSION in results.json, got %s\n' "$verdict" >&2
    ok=0
  fi
  base_override="$(jq -r '.model_overrides.base // ""' "$AB_RESULTS/results.json")"
  candidate_override="$(jq -r '.model_overrides.candidate // ""' "$AB_RESULTS/results.json")"
  base_model="$(jq -r '.cases[0].models.base' "$AB_RESULTS/results.json")"
  candidate_model="$(jq -r '.cases[0].models.candidate' "$AB_RESULTS/results.json")"
  [[ "$base_override" == "vendor/base-model" && "$base_model" == "vendor/base-model" ]] || { echo "FAIL: base model override not applied: override=$base_override manifest=$base_model" >&2; ok=0; }
  [[ "$candidate_override" == "vendor/candidate-model" && "$candidate_model" == "vendor/candidate-model" ]] || { echo "FAIL: candidate model override not applied: override=$candidate_override manifest=$candidate_model" >&2; ok=0; }
fi

if [[ "$ok" -eq 1 ]]; then
  echo "PASS: ab.sh correctly reports candidate regression (exit 12, REGRESSION in output, results.json valid)"
  exit 0
else
  echo "FAIL: ab_compare.sh assertions failed — see output above" >&2
  exit 1
fi
