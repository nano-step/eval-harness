#!/usr/bin/env bash
# lib/perf.sh — performance instrumentation for the harness (#EV-P).
# Portable millisecond clock: bash-5 $EPOCHREALTIME (no subprocess), else python3, else
# second-resolution date as a last resort (stock-macOS bash 3.2 has no sub-second date).

set -euo pipefail

_now_ms() {
  if [[ -n "${EPOCHREALTIME:-}" ]]; then
    # EPOCHREALTIME is "seconds.micros" (decimal point/comma is locale-dependent).
    local s="${EPOCHREALTIME%%[.,]*}" frac="${EPOCHREALTIME#*[.,]}"
    frac="${frac}000000"; frac="${frac:0:6}"
    echo $(( 10#$s * 1000 + 10#$frac / 1000 ))
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import time; print(int(time.time()*1000))'
  else
    echo $(( $(date +%s) * 1000 ))
  fi
}

# perf_warn_if_slow <label> <duration_ms> — warn (never fail) when a step exceeds the budget.
perf_warn_if_slow() {
  local label="$1" dur="$2" budget="${EVAL_STEP_BUDGET_MS:-}"
  [[ -z "$budget" ]] && return 0
  if [[ "$dur" =~ ^[0-9]+$ ]] && [[ "$dur" -gt "$budget" ]]; then
    echo "[eval-harness] WARN: step '$label' took ${dur}ms (> EVAL_STEP_BUDGET_MS=${budget}ms)" >&2
  fi
  return 0
}

export -f _now_ms perf_warn_if_slow
