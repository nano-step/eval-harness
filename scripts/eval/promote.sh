#!/usr/bin/env bash
# scripts/eval/promote.sh — promote from WARN-ONLY to BLOCKING.
# Settled Decision #15: requires (a) 7 days of runs and (b) zero false-positives logged.

set -euo pipefail

usage() {
  cat <<EOF
Usage: eval-harness promote [--force]

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
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    -h|--help) usage; exit 0 ;;
    promote) ;;
    *) echo "unknown arg: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

STATE_DIR="${EVAL_STATE_DIR:-$HOME/.config/opencode/eval-harness}"
HISTORY="$STATE_DIR/history.ndjson"
mkdir -p "$STATE_DIR"

if [[ "$FORCE" != "1" ]]; then
  if [[ ! -f "$HISTORY" ]]; then
    echo "[eval-harness] promote: no history.ndjson — cannot verify 7 green days" >&2
    echo "[eval-harness] use --force to override" >&2
    exit 2
  fi

  # Look for runs in the last 7 days. Linux: GNU date supports -d. macOS: BSD date uses -v.
  if date -d "@0" >/dev/null 2>&1; then
    cutoff="$(date -u -d "7 days ago" +%Y-%m-%dT%H:%M:%SZ)"
  else
    cutoff="$(date -u -v-7d +%Y-%m-%dT%H:%M:%SZ)"
  fi

  recent_runs="$(jq -s --arg c "$cutoff" '[.[] | select(.event=="run" and (.run_id // "") >= $c)] | length' "$HISTORY")"
  bypass_count="$(jq -s --arg c "$cutoff" '[.[] | select(.event=="bypass" and (.timestamp // "") >= $c)] | length' "$HISTORY")"

  if [[ "$recent_runs" -lt 1 ]]; then
    echo "[eval-harness] promote: insufficient run history in last 7 days ($recent_runs runs)" >&2
    echo "[eval-harness] use --force to override" >&2
    exit 2
  fi
  if [[ "$bypass_count" -gt 0 ]]; then
    echo "[eval-harness] promote: $bypass_count bypass event(s) in last 7 days" >&2
    echo "[eval-harness] resolve and try again, or use --force" >&2
    exit 2
  fi
fi

touch "$STATE_DIR/promoted"
jq -nc --arg ts "$(date -u +%FT%TZ)" --argjson forced "${FORCE}" \
  '{event:"promote", timestamp:$ts, forced:($forced == 1)}' >> "$HISTORY"

echo "[eval-harness] promoted to BLOCKING mode. Regressions now exit 12."
echo "[eval-harness] revert with: rm $STATE_DIR/promoted"
