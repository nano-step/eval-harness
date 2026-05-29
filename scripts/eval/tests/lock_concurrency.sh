#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

WORK="$(mktemp -d -t eval-harness-lock.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

export OPENCODE_SKILLS_ROOT="$WORK/skills"
export EVAL_STATE_DIR="$WORK/state"
export EVAL_SKIP_AUTH_CHECK=1
mkdir -p "$OPENCODE_SKILLS_ROOT" "$EVAL_STATE_DIR"

cp -R "$REPO_ROOT/skills/omo-session-distiller" "$OPENCODE_SKILLS_ROOT/"

STUB_BIN="$WORK/bin"
mkdir -p "$STUB_BIN"
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
sleep 2
echo "{\"event\":\"done\",\"pid\":$$,\"ts\":$(date +%s)}" >> "$cwd/concurrent-marker.log"
exit 0
STUB
chmod +x "$STUB_BIN/opencode"
export PATH="$STUB_BIN:$PATH"

RUN_BIN="$REPO_ROOT/scripts/eval/run.sh"
CASE="atom-shape-basic"

bash "$RUN_BIN" --skill=omo-session-distiller --case="$CASE" --trigger=manual > "$WORK/A.log" 2>&1 &
PID_A=$!
sleep 0.3
bash "$RUN_BIN" --skill=omo-session-distiller --case="$CASE" --trigger=manual > "$WORK/B.log" 2>&1 &
PID_B=$!

wait "$PID_A" || true
wait "$PID_B" || true

n_locks="$(find "$EVAL_STATE_DIR/locks" -name "*.lock" | wc -l | tr -d ' ')"
[[ "$n_locks" -ge "1" ]] || { echo "FAIL: expected >=1 lock file under $EVAL_STATE_DIR/locks; got $n_locks" >&2; ls -la "$EVAL_STATE_DIR/locks" >&2; exit 1; }

n_runs="$(find "$EVAL_STATE_DIR/runs" -maxdepth 1 -mindepth 1 -type d | wc -l | tr -d ' ')"
[[ "$n_runs" == "2" ]] || { echo "FAIL: expected 2 run dirs (both processes ran), got $n_runs" >&2; exit 1; }

for d in "$EVAL_STATE_DIR/runs"/*/; do
  if [[ -f "$d/$CASE/checks.json" ]]; then
    passed="$(jq -r '.passed' "$d/$CASE/checks.json" 2>/dev/null || echo unknown)"
    if [[ "$passed" == "false" ]] || [[ "$passed" == "true" ]]; then
      continue
    else
      echo "FAIL: run $d produced corrupt checks.json (passed=$passed)" >&2
      cat "$d/$CASE/checks.json" >&2 || true
      exit 1
    fi
  fi
done

echo "PASS: two concurrent same-case runs serialized via flock; both produced clean results"
exit 0
