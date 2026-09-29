#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
WORK="$(mktemp -d -t eval-harness-promote.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

write_history() {
  local state_dir="$1" include_bypass="$2"
  mkdir -p "$state_dir"
  python3 - "$state_dir/history.ndjson" "$include_bypass" <<'PY'
import datetime
import json
import sys

path, include_bypass = sys.argv[1:]
now = datetime.datetime.now(datetime.timezone.utc)
old = now - datetime.timedelta(days=8)
recent = now - datetime.timedelta(days=1)
records = [
    {"event": "run", "run_id": old.strftime("%Y-%m-%dT%H-%M-%SZ") + "-1"},
    {"event": "run", "timestamp": recent.isoformat().replace("+00:00", "Z"), "run_id": "recent-run"},
]
if include_bypass == "true":
    records.append({"event": "bypass", "timestamp": now.isoformat().replace("+00:00", "Z")})
with open(path, "w", encoding="utf-8") as stream:
    for record in records:
        stream.write(json.dumps(record) + "\n")
PY
}

EMPTY_STATE="$WORK/empty"
if EVAL_STATE_DIR="$EMPTY_STATE" bash "$REPO_ROOT/scripts/eval/status.sh" --promotion-ready >"$WORK/empty.out" 2>&1; then
  echo "FAIL: empty run history passed promotion readiness" >&2
  exit 1
fi
[[ ! -e "$EMPTY_STATE" ]] || { echo "FAIL: readiness check created state directory" >&2; exit 1; }

READY_STATE="$WORK/ready"
write_history "$READY_STATE" false
EVAL_STATE_DIR="$READY_STATE" bash "$REPO_ROOT/scripts/eval/status.sh" --promotion-ready >"$WORK/ready.out"
grep -q "promotion ready" "$WORK/ready.out" || { echo "FAIL: seven-day history was not ready" >&2; cat "$WORK/ready.out" >&2; exit 1; }
[[ ! -e "$READY_STATE/promoted" ]] || { echo "FAIL: status check promoted as a side effect" >&2; exit 1; }
EVAL_STATE_DIR="$READY_STATE" bash "$REPO_ROOT/scripts/eval/promote.sh" --check >"$WORK/check.out"
[[ ! -e "$READY_STATE/promoted" ]] || { echo "FAIL: promote --check changed mode" >&2; exit 1; }
EVAL_STATE_DIR="$READY_STATE" bash "$REPO_ROOT/scripts/eval/promote.sh" >"$WORK/promote.out"
[[ -f "$READY_STATE/promoted" ]] || { echo "FAIL: ready history did not promote" >&2; exit 1; }
[[ "$(jq -r '.forced' < <(tail -n 1 "$READY_STATE/history.ndjson"))" == "false" ]] || { echo "FAIL: normal promotion was recorded as forced" >&2; exit 1; }

BYPASS_STATE="$WORK/bypass"
write_history "$BYPASS_STATE" true
if EVAL_STATE_DIR="$BYPASS_STATE" bash "$REPO_ROOT/scripts/eval/promote.sh" --check >"$WORK/bypass.out" 2>&1; then
  echo "FAIL: recent bypass event passed promotion readiness" >&2
  exit 1
fi
[[ ! -e "$BYPASS_STATE/promoted" ]] || { echo "FAIL: failed readiness check promoted" >&2; exit 1; }
EVAL_STATE_DIR="$BYPASS_STATE" bash "$REPO_ROOT/scripts/eval/promote.sh" --force >"$WORK/forced.out"
[[ -f "$BYPASS_STATE/promoted" ]] || { echo "FAIL: --force did not promote" >&2; exit 1; }
[[ "$(jq -r '.forced' < <(tail -n 1 "$BYPASS_STATE/history.ndjson"))" == "true" ]] || { echo "FAIL: forced promotion provenance missing" >&2; exit 1; }

echo "PASS: promotion requires a seven-day history, checks bypasses, and honors read-only/force modes"
