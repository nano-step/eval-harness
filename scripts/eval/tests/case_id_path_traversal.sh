#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
WORK="$(mktemp -d -t eval-harness-case-id.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

export EVAL_STATE_DIR="$WORK/state"
export OPENCODE_SKILLS_ROOT="$WORK/skills"
export EVAL_SKIP_AUTH_CHECK=1
mkdir -p "$OPENCODE_SKILLS_ROOT/sut/evals/cases" "$WORK/bin"
cat > "$OPENCODE_SKILLS_ROOT/sut/evals/cases/malicious.yaml" <<'YAML'
schema_version: 2
id: ../../escape
eval_type: capability
prompt: noop
checks:
  - kind: file_exists
    path: absent.txt
YAML
cat > "$WORK/bin/opencode" <<'STUB'
#!/usr/bin/env bash
[[ "${1:-}" == "--version" ]] && { echo "1.15.10-stub"; exit 0; }
echo "{}"
STUB
chmod +x "$WORK/bin/opencode"
export PATH="$WORK/bin:$PATH"

if bash "$REPO_ROOT/scripts/eval/run.sh" --skill=sut >"$WORK/run.out" 2>&1; then
  echo "FAIL: unsafe case id did not make the run fail" >&2
  cat "$WORK/run.out" >&2
  exit 1
else
  rc=$?
fi
[[ "$rc" -eq 13 ]] || { echo "FAIL: unsafe YAML case id exit=$rc, expected 13" >&2; cat "$WORK/run.out" >&2; exit 1; }
run_id="$(sed -n 's/^\[eval-harness\] run_id=//p' "$WORK/run.out" | head -1)"
results="$EVAL_STATE_DIR/runs/$run_id/results.json"
[[ "$(jq -r '.cases[0].status' "$results")" == "ERROR" ]] || { echo "FAIL: unsafe case id was not represented as ERROR" >&2; cat "$results" >&2; exit 1; }
[[ ! -e "$EVAL_STATE_DIR/escape/case.yaml" ]] || { echo "FAIL: case id wrote outside the run directory" >&2; exit 1; }

if bash "$REPO_ROOT/scripts/eval/run.sh" --skill=sut --case=../escape >"$WORK/selector.out" 2>&1; then
  echo "FAIL: unsafe --case selector was accepted" >&2
  exit 1
else
  rc=$?
fi
[[ "$rc" -eq 2 ]] || { echo "FAIL: unsafe --case selector exit=$rc, expected 2" >&2; cat "$WORK/selector.out" >&2; exit 1; }

echo "PASS: case YAML IDs and --case selectors cannot traverse run-state paths"
