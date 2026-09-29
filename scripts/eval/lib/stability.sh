#!/usr/bin/env bash
# lib/stability.sh — 3-sample byte-identical determinism floor (Settled Decision #11).
# On FAIL, re-run the case 3 times; if all 3 produce byte-identical structured fields,
# the FAIL is "real" (attribution claim valid). Otherwise tag as "flaky".

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/portable.sh"

# Canonical digest over verdict-bearing checks only; free-text judge explanations and outputs are nondeterministic.
hash_checks() {
  local file="$1"
  jq -S '(.checks // []) | map({kind, passed, failed_check_id})' "$file" 2>/dev/null | portable_sha256_stdin | cut -d' ' -f1
}
export -f hash_checks

# Tamper-evidence for baselines; older baselines without checks_checksum remain readable.
baseline_integrity_hash() {
  local file="$1"
  jq -S '{passed, checks: ((.checks // []) | map({kind, passed, failed_check_id}))}' "$file" 2>/dev/null | portable_sha256_stdin | cut -d' ' -f1
}
inject_baseline_checksum() {
  local file="$1" checksum tmp
  checksum="$(baseline_integrity_hash "$file")"
  tmp="$file.ck.$$"
  jq --arg checksum "$checksum" '. + {checks_checksum: $checksum}' "$file" > "$tmp" && mv "$tmp" "$file"
}
verify_baseline_integrity() {
  local file="$1" stored actual
  stored="$(jq -r '.checks_checksum // ""' "$file" 2>/dev/null || echo "")"
  [[ -z "$stored" ]] && return 0
  actual="$(baseline_integrity_hash "$file")"
  [[ "$stored" == "$actual" ]]
}
export -f baseline_integrity_hash inject_baseline_checksum verify_baseline_integrity

# Usage: check_stability <runner_cmd> <samples_dir>
# runner_cmd: shell command that emits one results.json per invocation
# samples_dir: dir where samples will be written (sample-1.json, sample-2.json, sample-3.json)
# Emits: {samples: N, byte_identical: bool, hashes: [...]}
check_stability() {
  local runner_cmd="$1"
  local samples_dir="$2"
  mkdir -p "$samples_dir"

  local n=3
  local hashes=()
  for ((i=1; i<=n; i++)); do
    local out="$samples_dir/sample-$i.json"
    bash -c "$runner_cmd" > "$out" 2>"$samples_dir/sample-$i.err" || true
    # Hash only the "checks" subtree — ignore timestamps and run IDs which are non-deterministic by design
    local h
    h="$(hash_checks "$out")"
    hashes+=("$h")
  done

  local first="${hashes[0]}"
  local identical="true"
  for h in "${hashes[@]}"; do
    if [[ "$h" != "$first" ]]; then
      identical="false"
      break
    fi
  done

  local hashes_json
  hashes_json="$(printf '%s\n' "${hashes[@]}" | jq -R . | jq -s .)"

  jq -n \
    --arg samples "$n" \
    --argjson identical "$identical" \
    --argjson hashes "$hashes_json" \
    '{samples: ($samples | tonumber), byte_identical: $identical, hashes: $hashes}'
}

export -f check_stability

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  check_stability "$@"
fi
