#!/usr/bin/env bash
set -euo pipefail

usage() { echo "Usage: eval-harness status [--skill=<name>] [--latest] [--promotion-ready]"; }
SKILL=""; LATEST=0; PROMOTION_READY=0
for arg in "$@"; do
  case "$arg" in
    --skill=*) SKILL="${arg#*=}" ;;
    --latest) LATEST=1 ;;
    --promotion-ready) PROMOTION_READY=1 ;;
    -h|--help) usage; exit 0 ;;
    status) ;;
    *) echo "unknown arg: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

STATUS_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STATE_DIR="$(printenv EVAL_STATE_DIR 2>/dev/null || printf '%s' "$HOME/.config/opencode/eval-harness")"
RUNS_DIR="$STATE_DIR/runs"
if [[ "$PROMOTION_READY" == "1" ]]; then exec bash "$STATUS_SCRIPT_DIR/promote.sh" --check; fi
if [[ ! -d "$RUNS_DIR" ]]; then echo "[eval-harness] no runs yet"; exit 0; fi

_run_matches_skill() {
  local results="$1"
  [[ -z "$SKILL" ]] && return 0
  jq -e --arg s "$SKILL" '(.ab_skill==$s) or any(.cases[]?; (.env_manifest.skill_under_test // .skill // "")==$s)' "$results" >/dev/null 2>&1
}

skill_suffix=""
[[ -n "$SKILL" ]] && skill_suffix=" for skill $SKILL"
if [[ "$LATEST" == "1" ]]; then
  latest=""
  while IFS= read -r dir; do
    [[ -f "$dir/results.json" && -f "$dir/diff.md" ]] || continue
    if _run_matches_skill "$dir/results.json"; then latest="$dir"; break; fi
  done < <(ls -dt "$RUNS_DIR"/* 2>/dev/null || true)
  if [[ -z "$latest" ]]; then echo "[eval-harness] no completed run$skill_suffix"; exit 0; fi
  cat "$latest/diff.md"
  exit 0
fi

mode="$(if [[ -f "$STATE_DIR/promoted" ]]; then echo BLOCKING; else echo WARN-ONLY; fi)"
echo "[eval-harness] mode: $mode"
echo "[eval-harness] recent runs$skill_suffix:"
count=0
while IFS= read -r dir; do
  [[ -f "$dir/results.json" ]] || continue
  _run_matches_skill "$dir/results.json" || continue
  rid="$(jq -r '.run_id' "$dir/results.json")"
  verdict="$(jq -r '.verdict' "$dir/results.json")"
  trigger="$(jq -r '.trigger // "unknown"' "$dir/results.json")"
  totals="$(jq -r '"\(.summary.pass // 0)/\(.summary.total // 0)"' "$dir/results.json")"
  printf "  %s  %-12s  %-16s  %s\n" "$rid" "$trigger" "$verdict" "$totals"
  count=$((count+1))
  [[ "$count" -ge 10 ]] && break
done < <(ls -dt "$RUNS_DIR"/* 2>/dev/null || true)
if [[ "$count" -eq 0 ]]; then echo "  no matching runs"; fi
