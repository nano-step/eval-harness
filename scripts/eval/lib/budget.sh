#!/usr/bin/env bash
# lib/budget.sh — shared-state daily budget ledger for EVAL_BUDGET_USD (#12).
# Each run appends its cost to $STATE_DIR/budget-YYYY-MM-DD.ndjson (UTC by default,
# override with EVAL_BUDGET_TZ). Pre-run refuses to start once the day is already over
# budget; post-run records spend (failed/partial runs count — the tokens were paid).
# Local-only: a shared $HOME over NFS is out of scope.

set -euo pipefail

_budget_state_dir() { echo "${EVAL_STATE_DIR:-$HOME/.config/opencode/eval-harness}"; }

# Today's ledger path, honoring EVAL_BUDGET_TZ (default UTC).
budget_ledger_path() {
  local day
  day="$(TZ="${EVAL_BUDGET_TZ:-UTC}" date +%Y-%m-%d)"
  echo "$(_budget_state_dir)/budget-$day.ndjson"
}

# Sum measured cost_usd only; unavailable entries never masquerade as zero spend.
budget_spent_today() {
  local ledger; ledger="$(budget_ledger_path)"
  [[ -f "$ledger" ]] || { echo 0; return 0; }
  jq -s '[.[] | .cost_usd | select(type=="number")] | add // 0' "$ledger" 2>/dev/null || echo 0
}

budget_unmeasured_count() {
  local ledger; ledger="$(budget_ledger_path)"
  [[ -f "$ledger" ]] || { echo 0; return 0; }
  jq -s '[.[] | select((.cost_usd | type) != "number")] | length' "$ledger" 2>/dev/null || echo 1
}

# float_ge A B  -> exit 0 if A >= B (awk; no bc dependency).
_budget_ge() { awk -v a="$1" -v b="$2" 'BEGIN{exit !(a+0 >= b+0)}'; }

# budget_append <run_id> <cost_usd|<null>> <model> — serialized append of measured or unknown spend.
budget_append() {
  local run_id="$1" cost="$2" model="${3:-unknown}" cost_status
  if [[ "$cost" == "null" ]]; then cost_status="unavailable"
  elif [[ "$cost" =~ ^(0|[1-9][0-9]*)(\.[0-9]+)?$ ]]; then cost_status="measured"
  else echo "[eval-harness] invalid budget cost value: $cost" >&2; return 2; fi
  local ledger; ledger="$(budget_ledger_path)"
  mkdir -p "$(dirname "$ledger")"
  local line
  line="$(jq -nc --arg ts "$(date -u +%FT%TZ)" --arg rid "$run_id" --argjson c "$cost" --arg status "$cost_status" --arg m "$model" \
    '{ts:$ts,run_id:$rid,cost_usd:$c,cost_status:$status,model:$m}')"
  local lock="$ledger.lock"
  if command -v flock >/dev/null 2>&1; then
    ( exec 8>"$lock"; flock -w 10 -x 8 || true; printf '%s\n' "$line" >> "$ledger" )
  else
    local d="$lock.d" waited=0
    while ! mkdir "$d" 2>/dev/null; do [[ "$waited" -ge 100 ]] && break; sleep 0.1; waited=$((waited+1)); done
    printf '%s\n' "$line" >> "$ledger"
    rmdir "$d" 2>/dev/null || true
  fi
}

# budget_precheck — return 1 (and print message) if today's spend already meets/exceeds
# EVAL_BUDGET_USD. No-op (return 0) when EVAL_BUDGET_USD is unset/empty.
budget_precheck() {
  local cap="${EVAL_BUDGET_USD:-}"
  [[ -z "$cap" ]] && return 0
  local unmeasured; unmeasured="$(budget_unmeasured_count)"
  if [[ "$unmeasured" -gt 0 ]]; then
    echo "[eval-harness] budget blocked: $unmeasured ledger entry/entries have unavailable cost; reconcile spend before continuing." >&2
    return 1
  fi
  local spent; spent="$(budget_spent_today)"
  if _budget_ge "$spent" "$cap"; then
    echo "[eval-harness] daily budget exhausted: spent \$$spent of \$$cap today (EVAL_BUDGET_USD). Refusing to start." >&2
    return 1
  fi
  return 0
}

# budget_postcheck — return 1 (and print message) if today's spend now exceeds the cap.
budget_postcheck() {
  local cap="${EVAL_BUDGET_USD:-}"
  [[ -z "$cap" ]] && return 0
  local unmeasured; unmeasured="$(budget_unmeasured_count)"
  if [[ "$unmeasured" -gt 0 ]]; then
    echo "[eval-harness] budget spend is unmeasured for $unmeasured ledger entry/entries; future budget-gated runs are blocked until reconciled." >&2
    return 1
  fi
  local spent; spent="$(budget_spent_today)"
  if _budget_ge "$spent" "$cap"; then
    echo "[eval-harness] daily budget exhausted: spent \$$spent of \$$cap today (EVAL_BUDGET_USD)." >&2
    return 1
  fi
  return 0
}

export -f budget_ledger_path budget_spent_today budget_unmeasured_count budget_append budget_precheck budget_postcheck

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-}" in
    path)      budget_ledger_path ;;
    spent)     budget_spent_today ;;
    append)    shift; budget_append "$@" ;;
    precheck)  budget_precheck ;;
    postcheck) budget_postcheck ;;
    *) echo "usage: budget.sh {path|spent|append <run_id> <cost> <model>|precheck|postcheck}" >&2; exit 2 ;;
  esac
fi
