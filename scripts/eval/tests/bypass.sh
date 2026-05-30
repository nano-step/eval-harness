#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

WORK="$(mktemp -d -t eval-harness-bypass.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

export EVAL_STATE_DIR="$WORK/state"
export OPENCODE_SKILLS_ROOT="$WORK/skills"
export EVAL_SKIP_AUTH_CHECK=1
export EVAL_BYPASS=1
mkdir -p "$EVAL_STATE_DIR" "$OPENCODE_SKILLS_ROOT"

bash "$REPO_ROOT/scripts/eval/run.sh" --skill=some-skill --trigger=manual > "$WORK/out.log" 2>&1
RC=$?

if [[ "$RC" != "0" ]]; then
  echo "FAIL: EVAL_BYPASS=1 should exit 0, got $RC" >&2
  cat "$WORK/out.log" >&2
  exit 1
fi

grep -q "EVAL_BYPASS=1" "$WORK/out.log" || {
  echo "FAIL: missing bypass message in output" >&2
  cat "$WORK/out.log" >&2
  exit 1
}

HISTORY="$EVAL_STATE_DIR/history.ndjson"
if [[ ! -f "$HISTORY" ]]; then
  echo "FAIL: history.ndjson not created" >&2
  exit 1
fi

EVENT="$(jq -s '.[-1].event' "$HISTORY" 2>/dev/null || echo "PARSE_ERROR")"
if [[ "$EVENT" != '"bypass"' ]]; then
  echo "FAIL: last history event should be 'bypass', got $EVENT" >&2
  cat "$HISTORY" >&2
  exit 1
fi

SKILL_LOGGED="$(jq -s -r '.[-1].skill' "$HISTORY")"
TRIGGER_LOGGED="$(jq -s -r '.[-1].trigger' "$HISTORY")"
[[ "$SKILL_LOGGED" == "some-skill" ]] || { echo "FAIL: skill='$SKILL_LOGGED'" >&2; exit 1; }
[[ "$TRIGGER_LOGGED" == "manual" ]] || { echo "FAIL: trigger='$TRIGGER_LOGGED'" >&2; exit 1; }

echo "PASS: EVAL_BYPASS=1 exits 0 cleanly + logs {event:bypass, skill, trigger} to history.ndjson"
exit 0
