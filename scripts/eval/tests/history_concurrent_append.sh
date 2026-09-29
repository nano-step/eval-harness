#!/usr/bin/env bash
# Regression test for #5: concurrent run.sh processes must not interleave/corrupt
# history.ndjson. Launches N runs in parallel and asserts every history line is valid
# JSON and the expected count of "run" events landed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

WORK="$(mktemp -d -t eval-harness-hist.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

export OPENCODE_SKILLS_ROOT="$WORK/skills"
export EVAL_STATE_DIR="$WORK/state"
export EVAL_SKIP_AUTH_CHECK=1
mkdir -p "$OPENCODE_SKILLS_ROOT/test-skill/evals/cases"
# A shell check that passes without needing a transcript.
cat > "$OPENCODE_SKILLS_ROOT/test-skill/evals/cases/c1.yaml" <<YAML
schema_version: 2
id: c1
prompt: noop
checks:
  - kind: shell
    cmd: "printf 'ok'"
    expect_regex: "ok"
YAML

STUB_BIN="$WORK/bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/opencode" <<'STUB'
#!/usr/bin/env bash
[[ "${1:-}" == "--version" ]] && { echo "1.15.10-stub"; exit 0; }
# Write a non-empty transcript so the empty-transcript guard doesn't fire.
echo '{"type":"message"}'
exit 0
STUB
chmod +x "$STUB_BIN/opencode"
export PATH="$STUB_BIN:$PATH"

N=10
for ((i=0; i<N; i++)); do
  bash "$REPO_ROOT/scripts/eval/run.sh" --skill=test-skill --case=c1 >/dev/null 2>&1 &
done
wait

HIST="$EVAL_STATE_DIR/history.ndjson"
[[ -f "$HIST" ]] || { echo "FAIL: history.ndjson not created" >&2; exit 1; }

# Every line must be valid JSON (no interleaving). jq -c . over the file fails on corruption.
if ! jq -c . "$HIST" >/dev/null 2>"$WORK/jq.err"; then
  echo "FAIL: history.ndjson has invalid/interleaved JSON lines:" >&2
  cat "$WORK/jq.err" >&2
  exit 1
fi

run_events="$(jq -c 'select(.event=="run")' "$HIST" | wc -l | tr -d ' ')"
if [[ "$run_events" -ne "$N" ]]; then
  echo "FAIL: expected $N run events, got $run_events (lost appends under concurrency)" >&2
  exit 1
fi

echo "PASS: $N concurrent runs produced $run_events valid, non-interleaved history lines"
exit 0
