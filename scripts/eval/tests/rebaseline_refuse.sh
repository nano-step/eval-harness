#!/usr/bin/env bash
# Regression test for EV-P0b: rebaseline refuses a PASS->FAIL case (exit 12, baseline left
# intact) unless --accept-model-change is given, which rewrites it and logs a rebaseline
# audit record to history.ndjson.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
RUN="$REPO_ROOT/scripts/eval/run.sh"

WORK="$(mktemp -d -t eval-harness-rebase.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
export OPENCODE_SKILLS_ROOT="$WORK/skills"
export EVAL_STATE_DIR="$WORK/state"
export EVAL_SKIP_AUTH_CHECK=1
CASE_DIR="$OPENCODE_SKILLS_ROOT/test-skill/evals/cases"
BASE_DIR="$OPENCODE_SKILLS_ROOT/test-skill/evals/baselines"
mkdir -p "$CASE_DIR" "$BASE_DIR" "$EVAL_STATE_DIR"

cat > "$CASE_DIR/c1.yaml" <<YAML
schema_version: 2
id: c1
prompt: noop
checks:
  - kind: file_exists
    path: present.txt
YAML
# Baseline says this case PASSED (portable). The current run will FAIL it -> PASS->FAIL.
cat > "$BASE_DIR/c1.baseline.json" <<JSON
{"schema_version":2,"case_id":"c1","passed":true,"checks":[],"env_manifest":{"model_id":"old-model","portable":true},"last_seen_triggers":["baseline"]}
JSON

STUB_BIN="$WORK/bin"; mkdir -p "$STUB_BIN"
printf '#!/usr/bin/env bash\n[[ "${1:-}" == "--version" ]] && { echo stub; exit 0; }\necho "{}"\nexit 0\n' > "$STUB_BIN/opencode"
chmod +x "$STUB_BIN/opencode"
export PATH="$STUB_BIN:$PATH"

# 1. Without override -> refuse, exit 12, baseline unchanged (still passed:true).
set +e
bash "$RUN" rebaseline --skill=test-skill --case=c1 >"$WORK/refuse.log" 2>&1
rc=$?
set -e
[[ "$rc" -eq 12 ]] || { echo "FAIL: rebaseline without override should exit 12, got $rc" >&2; cat "$WORK/refuse.log" >&2; exit 1; }
[[ "$(jq -r '.passed' "$BASE_DIR/c1.baseline.json")" == "true" ]] || { echo "FAIL: baseline was mutated despite refusal" >&2; exit 1; }

# 2. With --accept-model-change -> rewrite (passed:false now) + audit record.
set +e
bash "$RUN" rebaseline --skill=test-skill --case=c1 --accept-model-change >"$WORK/override.log" 2>&1
rc=$?
set -e
[[ "$rc" -eq 0 ]] || { echo "FAIL: rebaseline --accept-model-change should exit 0, got $rc" >&2; cat "$WORK/override.log" >&2; exit 1; }
[[ "$(jq -r '.passed' "$BASE_DIR/c1.baseline.json")" == "false" ]] || { echo "FAIL: baseline not rewritten under override" >&2; exit 1; }
# portable marker preserved through rewrite
[[ "$(jq -r '.env_manifest.portable' "$BASE_DIR/c1.baseline.json")" == "true" ]] || { echo "FAIL: portable marker lost on rebaseline" >&2; exit 1; }
# audit record present
jq -e 'select(.event=="rebaseline" and .override==true and .cases_rewritten>=1)' "$EVAL_STATE_DIR/history.ndjson" >/dev/null \
  || { echo "FAIL: no rebaseline audit record in history.ndjson" >&2; cat "$EVAL_STATE_DIR/history.ndjson" >&2; exit 1; }

echo "PASS: rebaseline refuses PASS->FAIL (exit 12, baseline intact); --accept-model-change rewrites + audits + keeps portable"
exit 0
