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

# Internal: the primary RUNNERS_DIR, honoring EVAL_RUNNERS_DIR at call time so
# callers (and tests) can change it after sourcing.
_runner_dir() { printf '%s\n' "${EVAL_RUNNERS_DIR:-$_RUNNER_DIR_DEFAULT}"; }

# Internal: adapter search path, one directory per line, in precedence order:
# the trusted EVAL_RUNNERS_DIR override (when set) first, then the shipped
# runners directory. EVAL_RUNNERS_DIR therefore adds or overrides adapters; it
# never hides the shipped ones (langgraph-node, atd-sandbox, omp, claude-code, codex).
_runner_search_dirs() {
  local custom="${EVAL_RUNNERS_DIR:-}"
  if [[ -n "$custom" ]]; then printf '%s\n' "$custom"; fi
  if [[ "$custom" != "$_RUNNER_DIR_DEFAULT" ]]; then printf '%s\n' "$_RUNNER_DIR_DEFAULT"; fi
}

# Internal: the search path as a ", "-joined string for diagnostics.
_runner_search_desc() {
  local d out=""
  while IFS= read -r d; do
    out="${out:+$out, }$d"
  done < <(_runner_search_dirs)
  printf '%s\n' "$out"
}

# Usage: runner_name_valid <name>
# A runner name becomes a filename ($RUNNERS_DIR/<name>.sh) and is echoed in
# manifests, so it is restricted to a single path-safe token: it must start
# with a letter or digit, contain only letters, digits, '.', '_' and '-', and
# never contain '..'. Anything else (slashes, traversal, spaces) is rejected.
runner_name_valid() {
  local n="${1:-}"
  [[ -n "$n" && "$n" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && "$n" != *..* ]]
}

# Usage: runner_builtin_binary <name>
# Prints the host binary a built-in agent runner drives (omp -> omp,
# claude-code -> claude, codex -> codex). Returns 1 for every other name.
runner_builtin_binary() {
  case "${1:-}" in
    omp)         printf 'omp\n' ;;
    claude-code) printf 'claude\n' ;;
    codex)       printf 'codex\n' ;;
    *)           return 1 ;;
  esac
}

# Usage: preflight_check_adapter_runner <name>
# Preflight for every adapter-file runner that is not opencode / langgraph-node /
# atd-sandbox (which have their own probes). The name must be path-safe and
# resolve through the trusted resolve_runner (registry or $RUNNERS_DIR/<name>.sh).
# Built-in agent names (omp, claude-code, codex) additionally require ONLY their
# own binary on PATH; no provider credential or opencode state is probed.
preflight_check_adapter_runner() {
  local name="${1:-}" bin
  if ! runner_name_valid "$name"; then
    echo "[eval-harness] preflight FAIL: invalid runner name '$name' (letters, digits, '.', '_' and '-' only; no path separators or '..')" >&2
    return 1
  fi
  if ! resolve_runner "$name" >/dev/null 2>&1; then
    echo "[eval-harness] preflight FAIL: runner '$name' has no adapter (registry empty, no $name.sh in: $(_runner_search_desc))" >&2
    return 1
  fi
  if bin="$(runner_builtin_binary "$name")"; then
    if ! command -v "$bin" >/dev/null 2>&1; then
      echo "[eval-harness] preflight FAIL: runner=$name requires '$bin' on PATH" >&2
      return 1
    fi
  fi
  return 0
}

# Usage: runner_fingerprint <name> <workdir> <config_json>
# Best-effort fingerprint through the adapter's `fingerprint` subcommand. Prints
# the first stdout line, or "none" when the adapter fails, lacks the subcommand
# or prints nothing. Never fails: a fingerprint glitch must not abort the run.
runner_fingerprint() {
  local out="" rc=0
  out="$(dispatch_runner fingerprint "$@" 2>/dev/null)" || rc=$?
  out="$(printf '%s\n' "$out" | head -n 1 | tr -d '\r')"
  if [[ "$rc" != "0" || -z "$out" ]]; then out="none"; fi
  printf '%s\n' "$out"
}

# Usage: resolve_runner <name>
# Prints the runner script's absolute path on stdout. For "opencode",
# prints the literal "<implicit:opencode>" marker so callers can branch.
# Search order: in-memory registry, then $EVAL_RUNNERS_DIR/<name>.sh (trusted
# override), then the shipped runners directory. Returns 1 when none has it.
resolve_runner() {
  local name="$1"
  [[ -z "$name" ]] && { echo "resolve_runner: name required" >&2; return 2; }
  if ! runner_name_valid "$name"; then
    echo "resolve_runner: invalid runner name '$name' (letters, digits, '.', '_' and '-' only; no path separators or '..')" >&2
    return 2
  fi
  if [[ "$name" == "opencode" ]]; then
    printf '<implicit:opencode>\n'
    return 0
  fi
  local entry path dir d
  for entry in "${_RUNNER_REGISTRY[@]:-}"; do
    if [[ "${entry%%:*}" == "$name" ]]; then
      printf '%s\n' "${entry#*:}"
      return 0
    fi
  done
  while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    if dir="$(cd "$d" 2>/dev/null && pwd)"; then
      path="$dir/$name.sh"
      if [[ -f "$path" ]]; then
        printf '%s\n' "$path"
        return 0
      fi
    fi
  done < <(_runner_search_dirs)
  echo "resolve_runner: runner '$name' not found (registry empty, no $name.sh in: $(_runner_search_desc))" >&2
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
# listed first. Adapters discovered in $EVAL_RUNNERS_DIR and the shipped
# runners directory are listed alphabetically after, duplicates suppressed.
list_runners() {
  echo "opencode"
  local d f base
  while IFS= read -r d; do
    [[ -n "$d" && -d "$d" ]] || continue
    for f in "$d"/*.sh; do
      [[ -f "$f" ]] || continue
      base="$(basename "$f" .sh)"
      [[ "$base" == "opencode" ]] && continue
      echo "$base"
    done
  done < <(_runner_search_dirs) | sort -u
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
          local oc_rc=0
          spawn_opencode "$@" || oc_rc=$?
          return "$oc_rc"
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

export -f runner_name_valid runner_builtin_binary preflight_check_adapter_runner runner_fingerprint resolve_runner register_runner deregister_runner list_runners dispatch_runner

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
