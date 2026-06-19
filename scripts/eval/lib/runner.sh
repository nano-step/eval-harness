#!/usr/bin/env bash
# lib/runner.sh — runner-adapter registry + dispatch (KTD1, KTD2)
#
# A "runner" is a script implementing 4 subcommands: prepare, spawn,
# fingerprint, teardown. The full contract lives in docs/runners.md.
#
# "opencode" is the implicit default (KTD2). It is NOT a file in
# RUNNERS_DIR — dispatch_runner routes it to lib/spawn.sh::spawn_opencode
# for the spawn subcommand, and treats prepare/fingerprint/teardown as
# no-ops (opencode has no venv, no fingerprint beyond the manifest's
# opencode_version field, and tears down via the parent sandbox rmdir).
#
# In-memory registry (_RUNNER_REGISTRY) supports non-filesystem-anchored
# runners (future: plugins, dynamically-generated adapters). For U1, only
# the filesystem-anchored discovery is exercised.

set -euo pipefail

_RUNNER_DIR_DEFAULT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/runners"

# In-memory registry. Per-process; not exported across subshells.
_RUNNER_REGISTRY=()

# Internal: resolve the effective RUNNERS_DIR, honoring EVAL_RUNNERS_DIR
# at call time so callers (and tests) can change it after sourcing.
_runner_dir() { printf '%s\n' "${EVAL_RUNNERS_DIR:-$_RUNNER_DIR_DEFAULT}"; }

# Usage: resolve_runner <name>
# Prints the runner script's absolute path on stdout. For "opencode",
# prints the literal "<implicit:opencode>" marker so callers can branch.
# Returns 1 if the runner is neither the implicit one nor registered
# nor present at $RUNNERS_DIR/<name>.sh.
resolve_runner() {
  local name="$1"
  [[ -z "$name" ]] && { echo "resolve_runner: name required" >&2; return 2; }
  if [[ "$name" == "opencode" ]]; then
    printf '<implicit:opencode>\n'
    return 0
  fi
  local entry path
  for entry in "${_RUNNER_REGISTRY[@]:-}"; do
    if [[ "${entry%%:*}" == "$name" ]]; then
      printf '%s\n' "${entry#*:}"
      return 0
    fi
  done
  path="$(_runner_dir)/$name.sh"
  if [[ -f "$path" ]]; then
    printf '%s\n' "$path"
    return 0
  fi
  echo "resolve_runner: runner '$name' not found (registry empty, no $path)" >&2
  return 1
}

# Usage: register_runner <name> <path>
# Adds a runner to the in-memory registry. The path does not need to be
# under $RUNNERS_DIR — this is the escape hatch for ad-hoc test adapters.
register_runner() {
  local name="$1"
  local path="$2"
  [[ -z "$name" || -z "$path" ]] && { echo "register_runner: name and path required" >&2; return 2; }
  if [[ ! -f "$path" ]]; then
    echo "register_runner: file not found: $path" >&2
    return 1
  fi
  deregister_runner "$name" >/dev/null 2>&1 || true
  _RUNNER_REGISTRY+=("$name:$path")
  echo "[runner] registered: $name -> $path"
}

# Usage: deregister_runner <name>
# Removes a runner from the in-memory registry. Idempotent (no error if absent).
deregister_runner() {
  local name="$1"
  [[ -z "$name" ]] && { echo "deregister_runner: name required" >&2; return 2; }
  local filtered=() entry
  for entry in "${_RUNNER_REGISTRY[@]:-}"; do
    [[ "${entry%%:*}" == "$name" ]] && continue
    filtered+=("$entry")
  done
  _RUNNER_REGISTRY=("${filtered[@]:-}")
  echo "[runner] deregistered: $name"
}

# Usage: list_runners
# Prints all known runner names, one per line. "opencode" is always
# listed first. Filesystem-discovered runners are listed alphabetically
# after, with duplicates suppressed.
list_runners() {
  echo "opencode"
  local runners_dir
  runners_dir="$(_runner_dir)"
  if [[ -d "$runners_dir" ]]; then
    local f base
    for f in "$runners_dir"/*.sh; do
      [[ -f "$f" ]] || continue
      base="$(basename "$f" .sh)"
      [[ "$base" == "opencode" ]] && continue
      echo "$base"
    done | sort -u
  fi
}

# Usage: dispatch_runner <subcommand> <name> [args...]
# Invokes the named runner's subcommand.
#   - "opencode" routes the "spawn" subcommand to spawn_opencode in the
#     current shell (must be in scope). Other subcommands are no-ops.
#   - All other runners are invoked as `bash <path> <sub> <args...>`,
#     inheriting only exported env vars.
# Returns the runner's exit code.
dispatch_runner() {
  local sub="$1" name="$2"
  shift 2
  case "$sub" in
    prepare|spawn|fingerprint|teardown) ;;
    *) echo "dispatch_runner: unknown subcommand '$sub' (expected: prepare|spawn|fingerprint|teardown)" >&2
       return 2 ;;
  esac
  [[ -z "$name" ]] && { echo "dispatch_runner: name required" >&2; return 2; }

  if [[ "$name" == "opencode" ]]; then
    case "$sub" in
      spawn)
        if declare -F spawn_opencode >/dev/null 2>&1; then
          spawn_opencode "$@"
        else
          echo "dispatch_runner: spawn_opencode not in scope — source lib/spawn.sh first" >&2
          return 3
        fi
        ;;
      *)
        # KTD2: opencode has no venv, no fingerprint, no teardown.
        return 0
        ;;
    esac
  fi

  local path
  path="$(resolve_runner "$name")" || return $?
  bash "$path" "$sub" "$@"
}

export -f resolve_runner register_runner deregister_runner list_runners dispatch_runner

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-}" in
    list)             list_runners ;;
    resolve)          shift; resolve_runner "$@" ;;
    register)         shift; register_runner "$@" ;;
    deregister)       shift; deregister_runner "$@" ;;
    dispatch)         shift; dispatch_runner "$@" ;;
    *) cat <<'USAGE' >&2
usage: runner.sh <command> [args]

commands:
  list                              list all known runners
  resolve <name>                    print path to runner script (or <implicit:opencode>)
  register <name> <path>            add a runner to the in-memory registry
  deregister <name>                 remove a runner from the in-memory registry
  dispatch <sub> <name> [args...]   invoke subcommand on runner
USAGE
       exit 2
       ;;
  esac
fi
