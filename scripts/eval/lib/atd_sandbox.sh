#!/usr/bin/env bash
# lib/atd_sandbox.sh — helpers for the atd-sandbox runner adapter.
#
#   preflight_check_atd_sandbox [--quick] [<dependencies-dir>]
#       0 = Docker daemon reachable, pinned image present, effective confinement verified
#       1 = prerequisites unavailable (the case becomes ERROR; there is NO host fallback)
#   atd_sandbox_spawn <workdir> <runner_config_json> <transcript> [<prompt>]
#       Clears stale atd-out/transcript, then executes base+candidate in fresh containers.
#       exit 0 on completed evidence (even when outcomes are fail/error); non-zero on any
#       infrastructure/validation failure with an EMPTY transcript and no atd-out.

set -euo pipefail

_ATD_SANDBOX_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_ATD_SANDBOX_LIB_DIR/atd_attest.sh"
source "$_ATD_SANDBOX_LIB_DIR/portable.sh"
_ATD_SANDBOX_MJS="$_ATD_DISCOVERY_DIR/sandbox.mjs"

preflight_check_atd_sandbox() {
  local quick="" deps="" node
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --quick) quick="--quick" ;;
      *) deps="$1" ;;
    esac
    shift
  done
  if ! node="$(atd_resolve_node)"; then
    echo "[eval-harness] preflight FAIL: runner=atd-sandbox requires Node >= 18 on the host" >&2
    return 1
  fi
  if ! command -v docker >/dev/null 2>&1; then
    echo "[eval-harness] preflight FAIL: runner=atd-sandbox requires the docker CLI (no host fallback exists)" >&2
    return 1
  fi
  if ! command -v ssh-keygen >/dev/null 2>&1; then
    echo "[eval-harness] preflight FAIL: runner=atd-sandbox requires ssh-keygen to sign evidence" >&2
    return 1
  fi
  if ! "$node" "$_ATD_SANDBOX_MJS" preflight ${quick:+"$quick"} ${deps:+"--dependencies=$deps"} >/dev/null; then
    echo "[eval-harness] preflight FAIL: runner=atd-sandbox sandbox prerequisites are not satisfied" >&2
    return 1
  fi
  return 0
}

_atd_timeout_budget() {
  # Total host budget for one spawn: two bounded containers plus export/preflight slack.
  local cfg="$1" t
  t="$(printf '%s' "$cfg" | jq -r '.timeoutSeconds // 120' 2>/dev/null || echo 120)"
  t="${t%%.*}"
  [[ "$t" =~ ^[0-9]+$ && "$t" -ge 1 && "$t" -le 600 ]] || t=120
  echo $(( 2 * t + 900 ))
}

atd_sandbox_spawn() {
  local workdir="${1:-}" cfg="${2:-}" transcript="${3:-}" node rc=0 budget
  [[ -n "$workdir" && "$workdir" != /* ]] && workdir="$PWD/$workdir"
  [[ -n "$transcript" && "$transcript" != /* ]] && transcript="$PWD/$transcript"
  # Clear stale evidence FIRST: nothing from an earlier execution (or planted by fixtures) may survive.
  if [[ -n "$workdir" && -d "$workdir" ]]; then
    rm -rf "$workdir/atd-out" "$workdir"/.atd-out.stage-* 2>/dev/null || true
  fi
  [[ -n "$transcript" ]] && : > "$transcript"
  if [[ -z "$workdir" || -z "$transcript" || ! -d "$workdir" ]]; then
    echo "[atd-sandbox] spawn: workdir and transcript are required" >&2
    return 2
  fi
  if ! node="$(atd_resolve_node)"; then return 13; fi
  [[ -n "$cfg" ]] || cfg='{}'
  budget="$(_atd_timeout_budget "$cfg")"
  printf '%s' "$cfg" | run_with_timeout "$budget" "$node" "$_ATD_SANDBOX_MJS" run --workdir="$workdir" --transcript="$transcript" || rc=$?
  if [[ "$rc" != "0" ]]; then
    # Fail closed: an infrastructure failure must leave no evidence and an empty transcript.
    rm -rf "$workdir/atd-out" "$workdir"/.atd-out.stage-* 2>/dev/null || true
    : > "$transcript"
    return "$rc"
  fi
  # Exit 0 is only believable when the controller really published evidence and a transcript.
  if [[ ! -s "$transcript" || ! -f "$workdir/atd-out/attestation.json.sig" ]]; then
    echo "[atd-sandbox] controller exited 0 without publishing evidence; treating as failure" >&2
    rm -rf "$workdir/atd-out" "$workdir"/.atd-out.stage-* 2>/dev/null || true
    : > "$transcript"
    return 13
  fi
  return 0
}

export -f preflight_check_atd_sandbox atd_sandbox_spawn _atd_timeout_budget
