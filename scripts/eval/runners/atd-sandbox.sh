#!/usr/bin/env bash
# runners/atd-sandbox.sh — Docker-isolated base/candidate test execution (Autonomous Test Discovery).
# Runner contract (docs/runners.md): prepare | spawn | fingerprint | teardown.
#
#   prepare     <workdir> [<runner_config_json>]       full sandbox preflight (daemon, pinned image, confinement probe)
#   spawn       <workdir> <runner_config_json> <transcript> [<prompt>]
#                                                       executes generated tests on base and candidate in two fresh
#                                                       containers; writes <workdir>/atd-out (signed evidence)
#   fingerprint <workdir> <runner_config_json>         identity hash of runner scripts + policy + image + config
#   teardown    <workdir>                              removes containers left behind for this workdir
#
# runner_config keys: repository baseCommit candidateCommit candidateFile testsDir testsRel specFile
#                     dependencies image seed timeoutSeconds   (see scripts/eval/discovery/sandbox.mjs)
#   testsDir = HOST input root inside the case workdir (default 'tests'); testsRel = revision-relative
#   placement root ('.' = revision root, the default; candidate.testFile is relative to it).
# Exit codes: 0 evidence written (outcomes may still be fail/error); 13 infrastructure or validation
# failure (transcript empty, no atd-out); 124 host budget exhausted. There is no host fallback.

set -euo pipefail
_ATD_RUNNER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_ATD_RUNNER_DIR/../lib/atd_sandbox.sh"

atd_sandbox_prepare() {
  local workdir="${1:-}" cfg="${2:-}" deps=""
  if [[ -n "$cfg" ]]; then deps="$(printf '%s' "$cfg" | jq -r '.dependencies // empty' 2>/dev/null || true)"; fi
  preflight_check_atd_sandbox ${deps:+"$deps"}
}

atd_sandbox_fingerprint() {
  local cfg="${2:-}" node out
  node="$(atd_resolve_node 2>/dev/null)" || { printf '\n'; return 0; }
  [[ -n "$cfg" ]] || cfg='{}'
  out="$(printf '%s' "$cfg" | "$node" "$_ATD_SANDBOX_MJS" fingerprint 2>/dev/null)" || out=""
  printf '%s\n' "$out"
  return 0
}

atd_sandbox_teardown() {
  local workdir="${1:-}" node
  node="$(atd_resolve_node 2>/dev/null)" || return 0
  "$node" "$_ATD_SANDBOX_MJS" teardown --workdir="$workdir" >/dev/null 2>&1 || true
  return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  cmd="${1:-}"
  shift || true
  case "$cmd" in
    prepare)     atd_sandbox_prepare "$@" ;;
    spawn)       atd_sandbox_spawn "$@" ;;
    fingerprint) atd_sandbox_fingerprint "$@" ;;
    teardown)    atd_sandbox_teardown "$@" ;;
    *)
      echo "atd-sandbox.sh: unknown subcommand '$cmd' (expected: prepare|spawn|fingerprint|teardown)" >&2
      exit 2
      ;;
  esac
fi
