#!/usr/bin/env bash
# lib/yq-shim.sh — defines `yq` as a function backed by a Python helper.
# Used when the upstream `yq` binary is not on PATH.

_YQ_SHIM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v yq >/dev/null 2>&1; then
  yq() {
    python3 "$_YQ_SHIM_DIR/_yq.py" "$@"
  }
  export -f yq
fi
