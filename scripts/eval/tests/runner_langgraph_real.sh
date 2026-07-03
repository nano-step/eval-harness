#!/usr/bin/env bash
# tests/runner_langgraph_real.sh — real-LangGraph smoke test (R7b).
#
# Gated on EVAL_RUN_REAL_LANGGRAPH=1. Skips with exit 0 in normal CI.
# When enabled, this:
#   1. Installs langgraph into a fresh venv (`python3 -m venv` + `pip install`)
#   2. Runs the U3 example's `shell-basic` case via run.sh
#   3. Asserts the case PASSes end-to-end (no stub)
#
# Acceptance: the langgraph-node runner works against the real framework,
# not just the offline stub. This raises the bar for R7 from "stub
# matches stub" to "runner works against the real framework."
#
# Usage:
#   EVAL_RUN_REAL_LANGGRAPH=1 bash scripts/eval/tests/runner_langgraph_real.sh
#
# Expected runtime: ~30-90s (langgraph pip install dominates).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EVAL_BIN="$SCRIPT_DIR/../run.sh"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# Gate: must be explicitly enabled.
if [[ "${EVAL_RUN_REAL_LANGGRAPH:-0}" != "1" ]]; then
  echo "[runner_langgraph_real] SKIPPED — set EVAL_RUN_REAL_LANGGRAPH=1 to run"
  exit 0
fi

# Required tools.
if ! command -v python3 >/dev/null 2>&1; then
  echo "[runner_langgraph_real] FAIL: python3 not on PATH" >&2
  exit 2
fi

WORK="$(mktemp -d -t eval-harness-langgraph-real.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

export OPENCODE_SKILLS_ROOT="$WORK/skills"
export EVAL_STATE_DIR="$WORK/state"
export EVAL_SKIP_AUTH_CHECK=1
mkdir -p "$OPENCODE_SKILLS_ROOT" "$EVAL_STATE_DIR"

SKILL_NAME="langgraph-runner-example"
SKILL_DIR="$OPENCODE_SKILLS_ROOT/$SKILL_NAME"
mkdir -p "$SKILL_DIR/evals/cases" "$SKILL_DIR/evals/fixtures"

EX_SRC="$REPO_ROOT/examples/langgraph-runner"
cp "$EX_SRC/graph.py"         "$SKILL_DIR/evals/fixtures/graph.py"
cp "$EX_SRC/input.json"       "$SKILL_DIR/evals/fixtures/input.json"
cp "$EX_SRC/requirements.txt" "$SKILL_DIR/evals/fixtures/requirements.txt"
cp "$EX_SRC/cases/shell-basic.yaml" "$SKILL_DIR/evals/cases/shell-basic.yaml"

# --- Build a fresh venv and install langgraph --------------------------------
VENV_DIR="$WORK/.venv"
echo "[runner_langgraph_real] creating venv at $VENV_DIR"
python3 -m venv "$VENV_DIR" >/dev/null
# shellcheck disable=SC1091
source "$VENV_DIR/bin/activate"
echo "[runner_langgraph_real] pip install langgraph"
pip install --quiet --disable-pip-version-check -r "$SKILL_DIR/evals/fixtures/requirements.txt"
# Defer the rest to run.sh; the runner activates its own venv via EVAL_VENV_DIR
# if set. The simpler path: keep using this venv by setting EVAL_VENV_DIR.
export EVAL_VENV_DIR="$VENV_DIR"

# Verify the install actually worked.
python3 -c "import langgraph; print('langgraph', langgraph.__version__)"

# --- Run the case -----------------------------------------------------------
echo "[runner_langgraph_real] running shell-basic via run.sh"
set +e
bash "$EVAL_BIN" --skill="$SKILL_NAME" --case=shell-basic --trigger=manual \
  > "$WORK/run.log" 2>&1
ec=$?
set -e

echo "[runner_langgraph_real] run exit: $ec"
tail -20 "$WORK/run.log" | sed 's/^/  /'

LATEST_RUN="$(ls -dt "$EVAL_STATE_DIR/runs"/* 2>/dev/null | head -1)"
if [[ -z "$LATEST_RUN" || ! -f "$LATEST_RUN/results.json" ]]; then
  echo "[runner_langgraph_real] FAIL: no results.json at $LATEST_RUN" >&2
  exit 1
fi

PASSED="$(jq -r '.summary.pass // 0' "$LATEST_RUN/results.json")"
TOTAL="$(jq -r '.summary.total // 0' "$LATEST_RUN/results.json")"
echo "[runner_langgraph_real] summary: pass=$PASSED total=$TOTAL"

if [[ "$PASSED" == "1" && "$TOTAL" == "1" ]]; then
  echo "[runner_langgraph_real] PASS — real langgraph-node runner is green"
  exit 0
fi

echo "[runner_langgraph_real] FAIL — case did not pass cleanly" >&2
jq '.cases[0]' "$LATEST_RUN/results.json" 2>/dev/null | head -40 >&2
exit 1
