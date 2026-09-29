#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export EVAL_STATE_DIR="$TMP/state"
export EVAL_BUDGET_USD=1.00
source "$SCRIPT_DIR/lib/budget.sh"
budget_append run-unknown null test/model
[[ "$(budget_spent_today)" == "0" ]]
[[ "$(budget_unmeasured_count)" == "1" ]]
if budget_precheck >/dev/null 2>&1; then echo 'FAIL unknown spend allowed through budget precheck' >&2; exit 1; fi
if budget_postcheck >/dev/null 2>&1; then echo 'FAIL unknown spend not reported by postcheck' >&2; exit 1; fi
budget_append run-measured 0.25 test/model
[[ "$(budget_spent_today)" == "0.25" ]]
[[ "$(jq -s '[.[] | select(.cost_status=="unavailable" and .cost_usd==null)]|length' "$(budget_ledger_path)")" == "1" ]]
echo 'PASS unknown costs remain null and block budget-gated runs'
