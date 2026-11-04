#!/usr/bin/env bash
# lib/atd_attest.sh — verification of atd-sandbox signed evidence (atd.attestation/v1).
#
#   atd_verify <out-dir>            stdout: ONE JSON object
#       {"status":"valid|unavailable|invalid","reason":"...","trust":"...|null",
#        "attestationSha256":"...|null","executionIds":[...], ...extra fields when valid}
#       exit 0 = signature AND every referenced hash/path valid
#       exit 3 = unavailable (attestation.json or its .sig absent, out-dir missing)
#       exit 1 = invalid (bad signature, unknown signer, hash mismatch, path escape, symlink,
#                unattested file, verifier unavailable)
#   atd_blocking_eligible <out-dir> exit 0 only for a VALID attestation whose trust level is in the
#                trusted policy's blockingEligible list; local-same-user (the default) never is.
#
# Keys live in $EVAL_STATE_DIR/discovery/keys (or the external ATD_SIGNING_KEY_FILE /
# ATD_ALLOWED_SIGNERS_FILE); verification never reads key material from the evidence directory.

set -euo pipefail

_ATD_ATTEST_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ATD_DISCOVERY_DIR="$(cd "$_ATD_ATTEST_LIB_DIR/../discovery" && pwd)"
export _ATD_DISCOVERY_DIR

# Resolve a working Node >= 18 (ATD_NODE first, then PATH). Prints the path or fails.
atd_resolve_node() {
  local cand ver major
  for cand in "${ATD_NODE:-}" "$(command -v node 2>/dev/null || true)"; do
    [[ -n "$cand" ]] || continue
    ver="$("$cand" --version 2>/dev/null || true)"
    [[ "$ver" =~ ^v([0-9]+)\. ]] || continue
    major="${BASH_REMATCH[1]}"
    if [[ "$major" -ge 18 ]]; then printf '%s\n' "$cand"; return 0; fi
  done
  echo "[atd] no working Node >= 18 found (set ATD_NODE to a node binary)" >&2
  return 1
}

_atd_json_status() {
  # _atd_json_status <status> <reason>
  printf '{"status":"%s","reason":"%s","trust":null,"attestationSha256":null,"executionIds":[]}\n' "$1" "$2"
}

atd_verify() {
  local out_dir="${1:-}" node out rc=0
  if [[ -z "$out_dir" ]]; then _atd_json_status invalid "no out-dir given"; return 1; fi
  if ! node="$(atd_resolve_node 2>/dev/null)"; then _atd_json_status invalid "verifier unavailable: no working node"; return 1; fi
  out="$("$node" "$_ATD_DISCOVERY_DIR/attest.mjs" verify "$out_dir" 2>/dev/null)" || rc=$?
  case "$rc" in
    0|1|3) ;;
    *) _atd_json_status invalid "verifier failed (exit $rc)"; return 1 ;;
  esac
  if [[ "$out" != \{*\} ]] || [[ "$out" == *$'\n'* ]]; then
    _atd_json_status invalid "verifier produced no JSON"; return 1
  fi
  printf '%s\n' "$out"
  return "$rc"
}

atd_blocking_eligible() {
  local out_dir="${1:-}" res trust policy
  res="$(atd_verify "$out_dir" 2>/dev/null)" || return 1
  trust="$(printf '%s' "$res" | jq -r '.trust // ""')"
  policy="${EVAL_ATD_POLICY:-$_ATD_DISCOVERY_DIR/policy/atd-sandbox.v1.json}"
  [[ -n "$trust" ]] || return 1
  jq -e --arg t "$trust" '(.trust.blockingEligible // []) | index($t) != null' "$policy" >/dev/null 2>&1
}

export -f atd_resolve_node atd_verify atd_blocking_eligible _atd_json_status

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-}" in
    verify) shift; atd_verify "$@" ;;
    blocking-eligible) shift; atd_blocking_eligible "$@" ;;
    *) echo "usage: atd_attest.sh {verify|blocking-eligible} <out-dir>" >&2; exit 2 ;;
  esac
fi

