#!/usr/bin/env bash
set -euo pipefail

usage() { echo "Usage: eval-harness trend [--skill=<name>] [--last=N]"; }

SKILL=""; LAST=20
for arg in "$@"; do
  case "$arg" in
    --skill=*) SKILL="${arg#*=}" ;;
    --last=*)  LAST="${arg#*=}" ;;
    -h|--help) usage; exit 0 ;;
    trend)     ;;
    *) echo "unknown arg: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

STATE_DIR="${EVAL_STATE_DIR:-$HOME/.config/opencode/eval-harness}"
HISTORY="$STATE_DIR/history.ndjson"
if [[ ! -f "$HISTORY" ]]; then
  echo "[eval-harness] no history yet"
  exit 0
fi

printf "%-22s %-12s %-12s %-8s\n" "RUN_ID" "TRIGGER" "VERDICT" "PASS/TOT"
echo "$(printf '%.0s-' {1..60})"

tail -n "$LAST" "$HISTORY" | jq -r '
  select(.event == "run") |
  [.run_id, .trigger, .verdict, "\(.summary.pass)/\(.summary.total)"] |
  @tsv
' | while IFS=$'\t' read -r rid trig verd sum; do
  printf "%-22s %-12s %-12s %-8s\n" "$rid" "$trig" "$verd" "$sum"
done
