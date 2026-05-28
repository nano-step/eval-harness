#!/usr/bin/env bash
set -euo pipefail

usage() { echo "Usage: eval-harness status [--skill=<name>] [--latest]"; }

SKILL=""; LATEST=0
for arg in "$@"; do
  case "$arg" in
    --skill=*) SKILL="${arg#*=}" ;;
    --latest)  LATEST=1 ;;
    -h|--help) usage; exit 0 ;;
    status)    ;;
    *) echo "unknown arg: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

STATE_DIR="${EVAL_STATE_DIR:-$HOME/.config/opencode/eval-harness}"
RUNS_DIR="$STATE_DIR/runs"

if [[ ! -d "$RUNS_DIR" ]]; then
  echo "[eval-harness] no runs yet"
  exit 0
fi

if [[ "$LATEST" == "1" ]]; then
  latest="$(ls -dt "$RUNS_DIR"/* 2>/dev/null | head -1)"
  if [[ -z "$latest" ]] || [[ ! -f "$latest/results.json" ]]; then
    echo "[eval-harness] no completed run"; exit 0
  fi
  cat "$latest/diff.md"
  exit 0
fi

mode="$(if [[ -f "$STATE_DIR/promoted" ]]; then echo "BLOCKING"; else echo "WARN-ONLY"; fi)"
echo "[eval-harness] mode: $mode"

echo "[eval-harness] recent runs:"
ls -dt "$RUNS_DIR"/* 2>/dev/null | head -10 | while read -r d; do
  if [[ -f "$d/results.json" ]]; then
    rid="$(jq -r '.run_id' "$d/results.json")"
    verdict="$(jq -r '.verdict' "$d/results.json")"
    trig="$(jq -r '.trigger' "$d/results.json")"
    sum="$(jq -r '"\(.summary.pass)/\(.summary.total)"' "$d/results.json")"
    printf "  %s  %-12s  %-12s  %s\n" "$rid" "$trig" "$verdict" "$sum"
  fi
done
