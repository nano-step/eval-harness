#!/usr/bin/env bash
set -euo pipefail

usage() { echo "Usage: eval-harness trend [--skill=<name>] [--last=N]"; }
SKILL=""; LAST=20
for arg in "$@"; do
  case "$arg" in
    --skill=*) SKILL="${arg#*=}" ;;
    --last=*) LAST="${arg#*=}" ;;
    -h|--help) usage; exit 0 ;;
    trend) ;;
    *) echo "unknown arg: $arg" >&2; usage >&2; exit 2 ;;
  esac
done
[[ "$LAST" =~ ^[1-9][0-9]*$ ]] || { echo "--last must be a positive integer" >&2; exit 2; }
STATE_DIR="$(printenv EVAL_STATE_DIR 2>/dev/null || printf '%s' "$HOME/.config/opencode/eval-harness")"
HISTORY="$STATE_DIR/history.ndjson"
if [[ ! -f "$HISTORY" ]]; then echo "[eval-harness] no history yet"; exit 0; fi

printf "%-22s %-12s %-12s %-8s %s\n" "RUN_ID" "TRIGGER" "VERDICT" "PASS/TOT" "SKILL"
printf '%s\n' '--------------------------------------------------------------------------'
rows="$(jq -sr --arg skill "$SKILL" --argjson n "$LAST" '
  map(select(.event=="run" and ($skill=="" or .skill==$skill)))
  | .[(-$n):][]? | [.run_id,.trigger,.verdict,("\(.summary.pass // 0)/\(.summary.total // 0)"),(.skill // "unknown")] | @tsv
' "$HISTORY")"
if [[ -z "$rows" ]]; then
  if [[ -n "$SKILL" ]]; then echo "[eval-harness] no skill-tagged runs for $SKILL (legacy history may omit skill)"; else echo "[eval-harness] no run events"; fi
  exit 0
fi
while IFS=$'\t' read -r rid trigger verdict pass_tot skill; do
  printf "%-22s %-12s %-12s %-8s %s\n" "$rid" "$trigger" "$verdict" "$pass_tot" "$skill"
done <<< "$rows"
