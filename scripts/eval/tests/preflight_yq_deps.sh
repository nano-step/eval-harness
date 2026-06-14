#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

WORK="$(mktemp -d -t eval-harness-preflight-yq.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

make_stub() {
  local name="$1"
  local body="$2"
  cat > "$WORK/bin/$name" <<<"$body"
  chmod +x "$WORK/bin/$name"
}

run_preflight() {
  local out="$1"
  set +e
  (
    export PATH="$WORK/bin"
    export EVAL_SKIP_AUTH_CHECK=1
    # shellcheck disable=SC1091
    source "$REPO_ROOT/scripts/eval/lib/yq-shim.sh"
    # shellcheck disable=SC1091
    source "$REPO_ROOT/scripts/eval/lib/preflight.sh"
    preflight_check
  ) >"$out" 2>&1
  local rc=$?
  set -e
  return "$rc"
}

mkdir -p "$WORK/bin"
make_stub opencode '#!/bin/sh
exit 0'

missing_python="$WORK/missing-python.log"
if run_preflight "$missing_python"; then
  echo "FAIL: missing yq and python3 should fail preflight" >&2
  cat "$missing_python" >&2
  exit 1
fi
grep -q "neither 'yq' binary nor 'python3'" "$missing_python" || {
  echo "FAIL: missing-python diagnostic not found" >&2
  cat "$missing_python" >&2
  exit 1
}

make_stub python3 '#!/bin/sh
exit 1'

missing_pyyaml="$WORK/missing-pyyaml.log"
if run_preflight "$missing_pyyaml"; then
  echo "FAIL: missing PyYAML should fail preflight when yq is absent" >&2
  cat "$missing_pyyaml" >&2
  exit 1
fi
grep -q "python3 lacks pyyaml" "$missing_pyyaml" || {
  echo "FAIL: missing-pyyaml diagnostic not found" >&2
  cat "$missing_pyyaml" >&2
  exit 1
}

make_stub python3 '#!/bin/sh
if [ "${1:-}" = "-c" ] && [ "${2:-}" = "import yaml" ]; then
  exit 0
fi
exit 1'

fallback_ok="$WORK/fallback-ok.log"
if ! run_preflight "$fallback_ok"; then
  echo "FAIL: python3 with yaml should satisfy yq fallback preflight" >&2
  cat "$fallback_ok" >&2
  exit 1
fi

rm -f "$WORK/bin/python3"
make_stub yq '#!/bin/sh
exit 0'

yq_ok="$WORK/yq-ok.log"
if ! run_preflight "$yq_ok"; then
  echo "FAIL: yq on PATH should not require python3" >&2
  cat "$yq_ok" >&2
  exit 1
fi

echo "PASS: preflight reports missing yq fallback deps and accepts yq or python3+pyyaml"
exit 0
