#!/usr/bin/env bash
set -euo pipefail

acquire_lock() {
  local lock_key="$1"
  local cmd="$2"
  local timeout="${3:-30}"

  local lock_dir="${EVAL_STATE_DIR:-$HOME/.config/opencode/eval-harness}/locks"
  mkdir -p "$lock_dir"
  local safe_key
  safe_key="$(printf '%s' "$lock_key" | tr '/ ' '__')"
  local lock_file="$lock_dir/$safe_key.lock"

  if command -v flock >/dev/null 2>&1; then
    (
      exec 9>"$lock_file"
      if ! flock -w "$timeout" -x 9; then
        echo "[eval-harness] lock timeout after ${timeout}s on $lock_key" >&2
        exit 75
      fi
      bash -c "$cmd"
    )
    return $?
  fi

  local mkdir_lock="${lock_file}.d"
  local waited=0
  while ! mkdir "$mkdir_lock" 2>/dev/null; do
    if [[ "$waited" -ge "$timeout" ]]; then
      echo "[eval-harness] lock timeout after ${timeout}s on $lock_key (mkdir fallback)" >&2
      return 75
    fi
    sleep 1
    waited=$((waited+1))
  done
  trap 'rmdir "$mkdir_lock" 2>/dev/null || true' RETURN
  bash -c "$cmd"
  local rc=$?
  rmdir "$mkdir_lock" 2>/dev/null || true
  trap - RETURN
  return "$rc"
}

export -f acquire_lock

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-}" in
    acquire) shift; acquire_lock "$@" ;;
    *) echo "usage: lock.sh acquire <key> <cmd> [timeout_sec]" >&2; exit 2 ;;
  esac
fi
