#!/usr/bin/env bash
# scripts/eval/promote.sh — promote from WARN-ONLY to BLOCKING.
# Settled Decision #15: requires at least 7 days of run history and no recent bypasses.

set -euo pipefail

usage() {
  cat <<EOF
Usage: eval-harness promote [--check] [--force]
  --check     Report promotion readiness without changing state.

Promotes the harness from WARN-ONLY (default since install) to BLOCKING.
After promotion:
  - exit code 12 on regression actually blocks pre-push / sync-publish
  - bypass remains available via EVAL_BYPASS=1

Requirements (unless --force):
  - At least 7 days of run history in history.ndjson
  - No 'bypass' events in the last 7 days
EOF
}

FORCE=0
CHECK=0
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    --check) CHECK=1 ;;
    -h|--help) usage; exit 0 ;;
    promote) ;;
    *) echo "unknown arg: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ "$FORCE" == "1" && "$CHECK" == "1" ]]; then
  echo "error: --check cannot be combined with --force" >&2
  exit 2
fi

STATE_DIR="${EVAL_STATE_DIR:-$HOME/.config/opencode/eval-harness}"
HISTORY="$STATE_DIR/history.ndjson"

promotion_report() {
  python3 - "$HISTORY" <<'PY'
import datetime
import json
import os
import re
import sys

history = sys.argv[1]
now = datetime.datetime.now(datetime.timezone.utc)
cutoff = now - datetime.timedelta(days=7)

def timestamp(record):
    value = record.get("timestamp")
    if isinstance(value, str):
        try:
            parsed = datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
            return parsed.replace(tzinfo=datetime.timezone.utc) if parsed.tzinfo is None else parsed.astimezone(datetime.timezone.utc)
        except ValueError:
            pass
    run_id = record.get("run_id", "")
    match = re.match(r"^(\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}Z)", run_id)
    if match:
        try:
            return datetime.datetime.strptime(match.group(1), "%Y-%m-%dT%H-%M-%SZ").replace(tzinfo=datetime.timezone.utc)
        except ValueError:
            pass
    return None

records = []
malformed = 0
if os.path.isfile(history):
    with open(history, encoding="utf-8") as stream:
        for line in stream:
            if not line.strip():
                continue
            try:
                record = json.loads(line)
                if not isinstance(record, dict):
                    raise ValueError("history event is not an object")
                records.append(record)
            except (json.JSONDecodeError, ValueError):
                malformed += 1

runs = [timestamp(record) for record in records if record.get("event") == "run"]
runs = [value for value in runs if value is not None]
bypasses = [record for record in records if record.get("event") == "bypass"]
recent_bypasses = 0
unknown_bypasses = 0
for record in bypasses:
    value = timestamp(record)
    if value is None:
        unknown_bypasses += 1
    elif value >= cutoff:
        recent_bypasses += 1

spans_week = bool(runs) and min(runs) <= cutoff and max(runs) >= cutoff
ready = spans_week and recent_bypasses == 0 and unknown_bypasses == 0 and malformed == 0
print(f"[eval-harness] promotion readiness: {len(runs)} timestamped runs; {recent_bypasses} bypass(es) in the last 7 days")
if not spans_week:
    print("[eval-harness] promotion not ready: run history must span at least 7 days and include a run in the last 7 days")
if recent_bypasses or unknown_bypasses:
    print(f"[eval-harness] promotion not ready: {recent_bypasses} recent and {unknown_bypasses} unparseable bypass event(s)")
if malformed:
    print(f"[eval-harness] promotion not ready: {malformed} malformed history record(s)")
if ready:
    print("[eval-harness] promotion ready")
sys.exit(0 if ready else 1)
PY
}

_do_promote() {
  local forced="$1"
  mkdir -p "$STATE_DIR"
  touch "$STATE_DIR/promoted"
  jq -nc --arg ts "$(date -u +%FT%TZ)" --argjson forced "$forced" '{event:"promote", timestamp:$ts, forced:($forced == 1)}' >> "$HISTORY"
  echo "[eval-harness] promoted to BLOCKING mode. Regressions now exit 12."
  echo "[eval-harness] revert with: rm $STATE_DIR/promoted"
}

if [[ "$CHECK" == "1" ]]; then
  promotion_report || exit 2
  exit 0
fi

if [[ "$FORCE" != "1" ]]; then
  if ! promotion_report; then
    echo "[eval-harness] promote: criteria not met; use --force only after accepting the risk" >&2
    exit 2
  fi
fi

_do_promote "$FORCE"
