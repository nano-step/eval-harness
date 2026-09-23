#!/usr/bin/env bash
set -euo pipefail

portable_sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$@"
    return $?
  fi
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$@"
    return $?
  fi
  echo "[eval-harness] missing sha256 tool: install sha256sum or shasum" >&2
  return 127
}

portable_sha256_stdin() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum
    return $?
  fi
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256
    return $?
  fi
  echo "[eval-harness] missing sha256 tool: install sha256sum or shasum" >&2
  return 127
}

portable_sort_nul() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c '
import sys

items = sys.stdin.buffer.read().split(b"\0")
if items and items[-1] == b"":
    items.pop()
for item in sorted(items):
    sys.stdout.buffer.write(item + b"\0")
'
    return $?
  fi
  echo "[eval-harness] missing sort helper: install python3" >&2
  return 127
}

resolve_timeout_bin() {
  if command -v timeout >/dev/null 2>&1; then
    command -v timeout
    return 0
  fi
  if command -v gtimeout >/dev/null 2>&1; then
    command -v gtimeout
    return 0
  fi
  echo "[eval-harness] missing timeout tool: install timeout or gtimeout" >&2
  return 127
}

run_with_timeout() {
  local max_seconds="$1"
  shift
  local timeout_bin
  if timeout_bin="$(resolve_timeout_bin 2>/dev/null)"; then
    "$timeout_bin" "$max_seconds" "$@"
    return $?
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$max_seconds" "$@" <<'PY'
import subprocess
import sys

timeout = float(sys.argv[1])
cmd = sys.argv[2:]
if not cmd:
    sys.exit(2)
try:
    completed = subprocess.run(cmd, timeout=timeout)
    sys.exit(completed.returncode)
except subprocess.TimeoutExpired:
    sys.exit(124)
except FileNotFoundError:
    print(f"[eval-harness] command not found: {cmd[0]}", file=sys.stderr)
    sys.exit(127)
PY
    return $?
  fi
  echo "[eval-harness] missing timeout tool: install timeout, gtimeout, or python3" >&2
  return 127
}

export -f portable_sha256_file portable_sha256_stdin portable_sort_nul resolve_timeout_bin run_with_timeout
