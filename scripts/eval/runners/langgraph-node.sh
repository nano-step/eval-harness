#!/usr/bin/env bash
# runners/langgraph-node.sh — LangGraph adapter for the eval-harness.
# Runner contract: 4 subcommands. The full spec lives in docs/runners.md.
# lib/runner.sh dispatches to this script as `bash <path> <sub> <args>`.
#
#   prepare <workdir> [<runner_config_json>]
#                                 — create venv, install deps, import-check module
#   spawn   <workdir> <input> <output> <transcript> [<runner_config_json>]
#                                 — invoke graph, capture stdout/stderr,
#                                   emit JSONL events
#   fingerprint <module_path>     — stable hash of graph source + @tool bodies
#   teardown <workdir>            — remove venv (unless EVAL_VENV_CACHE=1)
#
# Env vars (set by run.sh per case, or by the caller):
#   EVAL_SKIP_VENV_PREPARE=1      Skip venv creation. For tests that mock python.
#   EVAL_VENV_DIR                 Override venv path. Default: <workdir>/.venv
#   EVAL_VENV_CACHE=1             Reuse venv across runs (cached at
#                                 EVAL_VENV_CACHE_DIR or $XDG_CACHE_HOME).
#   EVAL_VENV_CACHE_DIR           Override cache root. Default: see _cache_root.
#   EVAL_FAIL_ON_NO_LLM=1         Refuse to run if no LLM-backed tool is detected
#                                 (a coarse proxy for "this graph is a real
#                                 LangGraph agent" vs "this is a stub").
#
# Transcript event shape (one JSON object per line):
#   {"event": "step", "type": "tool", "content": "...", "ts": "..."}
#   {"event": "step", "type": "assistant", "content": "...", "usage": {...}, "ts": "..."}
#   {"event": "result", "content": "<final answer>", "ts": "..."}
#   {"event": "error", "content": "<message>", "ts": "..."}
# The shape is intentionally compatible with opencode's --format json output
# so score.sh's output_contains / transcript_contains checks work unchanged.

set -euo pipefail

# --- helpers ---------------------------------------------------------------

# Usage: _resolve_venv_python <venv_dir>
# Prints the absolute path to the venv's python binary, handling
# POSIX (bin/python3) and Windows (Scripts/python.exe) layouts.
_resolve_venv_python() {
  local venv_dir="$1"
  if [[ -x "$venv_dir/bin/python3" ]]; then
    printf '%s\n' "$venv_dir/bin/python3"
  elif [[ -x "$venv_dir/Scripts/python.exe" ]]; then
    printf '%s\n' "$venv_dir/Scripts/python.exe"
  elif [[ -x "$venv_dir/Scripts/python3.exe" ]]; then
    printf '%s\n' "$venv_dir/Scripts/python3.exe"
  else
    return 1
  fi
}

# Usage: _venv_python_or_system <venv_dir>
# If the venv has a python binary, return it; otherwise fall back to
# the system python3 (used when EVAL_SKIP_VENV_PREPARE=1 and the test
# never created a venv).
_venv_python_or_system() {
  local venv_dir="$1"
  if [[ -d "$venv_dir" ]]; then
    if py="$(_resolve_venv_python "$venv_dir")"; then
      printf '%s\n' "$py"
      return 0
    fi
  fi
  command -v python3 || { echo "langgraph-node: python3 not on PATH" >&2; return 1; }
}

# Usage: _cache_root
# Returns the absolute path to the venv cache root. Honors
# EVAL_VENV_CACHE_DIR; otherwise uses $XDG_CACHE_HOME/eval-harness/langgraph-venv
# (or $HOME/.cache/... on Linux, $HOME/Library/Caches/... on macOS).
_cache_root() {
  if [[ -n "${EVAL_VENV_CACHE_DIR:-}" ]]; then
    printf '%s\n' "$EVAL_VENV_CACHE_DIR"
    return 0
  fi
  if [[ -n "${XDG_CACHE_HOME:-}" ]]; then
    printf '%s\n' "$XDG_CACHE_HOME/eval-harness/langgraph-venv"
    return 0
  fi
  case "$(uname -s)" in
    Darwin) printf '%s\n' "$HOME/Library/Caches/eval-harness/langgraph-venv" ;;
    *)      printf '%s\n' "${XDG_CACHE_HOME:-$HOME/.cache}/eval-harness/langgraph-venv" ;;
  esac
}

# Usage: _requirements_hash <workdir>
# Hashes requirements.txt in <workdir>; empty string if absent.
_requirements_hash() {
  local workdir="$1"
  if [[ -f "$workdir/requirements.txt" ]]; then
    sha256sum "$workdir/requirements.txt" | cut -d' ' -f1
  else
    printf '%s\n' "no-requirements"
  fi
}

# Usage: _parse_entry_point <entry_point>
# Splits "module.py:symbol" into MODULE / SYMBOL. Sets _EP_MODULE and
# _EP_SYMBOL in the caller's scope (we use globals — easier than
# echo-from-function when downstream uses the values multiple times).
# Returns 0 on success, 1 on malformed input.
_parse_entry_point() {
  local ep="$1"
  _EP_MODULE=""
  _EP_SYMBOL=""
  if [[ -z "$ep" ]] || ! [[ "$ep" == *:* ]]; then
    return 1
  fi
  _EP_MODULE="${ep%%:*}"
  _EP_SYMBOL="${ep#*:}"
  [[ -n "$_EP_MODULE" && -n "$_EP_SYMBOL" ]]
}

# Usage: _jsonl_event <json>
# Writes <json> + newline to stdout. Used by spawn to emit events.
_jsonl_event() {
  printf '%s\n' "$1"
}

# Usage: _now_iso
# Returns current UTC timestamp in ISO 8601 (Z suffix).
_now_iso() {
  date -u +"%Y-%m-%dT%H:%M:%S.%3NZ" 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# --- prepare ---------------------------------------------------------------

# Usage: langgraph_node_prepare <workdir> [<runner_config_json>]
# Creates the venv, installs requirements, import-checks the entry-point
# module. Honors EVAL_SKIP_VENV_PREPARE=1 (test mode).
langgraph_node_prepare() {
  local workdir="${1:-}"
  local runner_config="${2:-${EVAL_RUNNER_CONFIG_JSON:-}}"

  if [[ "${EVAL_SKIP_VENV_PREPARE:-0}" == "1" ]]; then
    echo "[langgraph-node] prepare:skipped (EVAL_SKIP_VENV_PREPARE=1)" >&2
    return 0
  fi

  local venv_dir="${EVAL_VENV_DIR:-$workdir/.venv}"
  local req_hash
  req_hash="$(_requirements_hash "$workdir")"

  # Cache lookup
  if [[ "${EVAL_VENV_CACHE:-0}" == "1" ]]; then
    local cache_root
    cache_root="$(_cache_root)"
    local cached="$cache_root/$req_hash"
    if [[ -d "$cached" ]] && _resolve_venv_python "$cached" >/dev/null 2>&1; then
      mkdir -p "$(dirname "$venv_dir")"
      # Symlink rather than copy so the cache is shared in-place.
      ln -snf "$cached" "$venv_dir" 2>/dev/null || {
        # Symlinks can fail on Windows without privilege; fall back to copy.
        rm -rf "$venv_dir"
        cp -R "$cached" "$venv_dir"
      }
      echo "[langgraph-node] prepare:cache-hit venv=$venv_dir cache=$cached" >&2
      return 0
    fi
  fi

  # Create venv fresh
  if ! command -v python3 >/dev/null 2>&1; then
    echo "[langgraph-node] prepare:FAIL python3 not on PATH" >&2
    return 1
  fi
  mkdir -p "$(dirname "$venv_dir")"
  python3 -m venv "$venv_dir" 2>/dev/null || {
    echo "[langgraph-node] prepare:FAIL venv creation at $venv_dir failed" >&2
    return 1
  }

  local py
  if ! py="$(_resolve_venv_python "$venv_dir")"; then
    echo "[langgraph-node] prepare:FAIL venv has no python binary at $venv_dir" >&2
    return 1
  fi

  # Install requirements (if present)
  if [[ -f "$workdir/requirements.txt" ]]; then
    "$py" -m pip install --quiet --disable-pip-version-check -r "$workdir/requirements.txt" >&2 || {
      echo "[langgraph-node] prepare:FAIL pip install failed" >&2
      return 1
    }
  fi

  # Import-check the entry-point module (best-effort; useful surface for
  # catching missing files / bad syntax early, before spawn pays the cost)
  if [[ -n "$runner_config" ]] && command -v jq >/dev/null 2>&1; then
    local ep
    ep="$(printf '%s' "$runner_config" | jq -r '.entry_point // empty' 2>/dev/null || true)"
    if [[ -n "$ep" ]]; then
      if _parse_entry_point "$ep"; then
        if [[ ! -f "$workdir/$_EP_MODULE.py" ]] && [[ ! -f "$workdir/$_EP_MODULE" ]]; then
          echo "[langgraph-node] prepare:FAIL module file not found: $workdir/$_EP_MODULE(.py)" >&2
          return 1
        fi
        ( cd "$workdir" && "$py" -c "import sys; sys.path.insert(0, '.'); import $_EP_MODULE" ) >&2 || {
          echo "[langgraph-node] prepare:FAIL import $_EP_MODULE failed" >&2
          return 1
        }
      fi
    fi
  fi

  # Cache the freshly prepared venv
  if [[ "${EVAL_VENV_CACHE:-0}" == "1" ]]; then
    local cache_root
    cache_root="$(_cache_root)"
    local dest="$cache_root/$req_hash"
    mkdir -p "$cache_root"
    rm -rf "$dest"
    cp -R "$venv_dir" "$dest"
    echo "[langgraph-node] prepare:cache-stored venv=$venv_dir cache=$dest" >&2
  fi

  echo "[langgraph-node] prepare:ok venv=$venv_dir" >&2
  return 0
}

# --- spawn -----------------------------------------------------------------

# Usage: langgraph_node_spawn <workdir> <input> <output> <transcript> [<runner_config_json>]
# Invokes the graph in the venv. Captures stdout to <output>, captures
# stderr to <transcript>.err, emits JSONL events to <transcript>.
#   - On success: writes transcript events; graph's output.json is the
#     source of truth for jq_path_contains / file-output checks.
#   - On failure: writes a single {"event":"error",...} event so
#     run_all_checks still produces a checks.json.
langgraph_node_spawn() {
  local workdir="${1:-}"
  local input="${2:-}"
  local output="${3:-}"
  local transcript="${4:-}"
  local runner_config="${5:-${EVAL_RUNNER_CONFIG_JSON:-}}"

  if [[ -n "$transcript" ]]; then
    : > "$transcript"
  fi

  if [[ -z "$workdir" || -z "$transcript" ]]; then
    _jsonl_event "{\"event\":\"error\",\"content\":\"langgraph_node_spawn: workdir and transcript are required\",\"ts\":\"$(_now_iso)\"}" >> "$transcript"
    return 2
  fi

  if [[ -z "$runner_config" ]] || ! command -v jq >/dev/null 2>&1; then
    _jsonl_event "{\"event\":\"error\",\"content\":\"langgraph_node_spawn: runner_config (with entry_point) is required and jq must be on PATH\",\"ts\":\"$(_now_iso)\"}" >> "$transcript"
    return 13
  fi

  local ep
  ep="$(printf '%s' "$runner_config" | jq -r '.entry_point // empty' 2>/dev/null || true)"
  if [[ -z "$ep" ]]; then
    _jsonl_event "{\"event\":\"error\",\"content\":\"runner_config.entry_point is required (format: module.py:symbol)\",\"ts\":\"$(_now_iso)\"}" >> "$transcript"
    return 13
  fi

  if ! _parse_entry_point "$ep"; then
    _jsonl_event "{\"event\":\"error\",\"content\":\"malformed entry_point '$ep' (expected module.py:symbol)\",\"ts\":\"$(_now_iso)\"}" >> "$transcript"
    return 13
  fi

  local venv_dir="${EVAL_VENV_DIR:-$workdir/.venv}"
  local py
  if ! py="$(_venv_python_or_system "$venv_dir")"; then
    _jsonl_event "{\"event\":\"error\",\"content\":\"no python3 found (venv=$venv_dir, system PATH)\",\"ts\":\"$(_now_iso)\"}" >> "$transcript"
    return 13
  fi

  # Emit a "started" event so consumers can see the run began even if
  # the graph hangs or the venv is misconfigured.
  _jsonl_event "{\"event\":\"start\",\"module\":\"$_EP_MODULE\",\"symbol\":\"$_EP_SYMBOL\",\"input\":\"$input\",\"output\":\"$output\",\"ts\":\"$(_now_iso)\"}" >> "$transcript"

  local start_ts end_ts rc
  start_ts="$(date +%s)"

  # Run the graph. PYTHONPATH=<workdir> so `python3 -m graph` finds
  # graph.py materialized into the workdir by run.sh's fixture step.
  # All args passed via --input/--output so the graph's own CLI
  # surface stays framework-agnostic.
  set +e
  (
    cd "$workdir"
    PYTHONPATH="$workdir${PYTHONPATH:+:$PYTHONPATH}" \
    "$py" -m "$_EP_MODULE" --input "$input" --output "$output" \
      >"$transcript.stdout" 2>"$transcript.stderr"
  )
  rc=$?
  set -e

  end_ts="$(date +%s)"
  local elapsed=$(( end_ts - start_ts ))

  # Emit a step event with stdout content (helps transcript_contains find
  # the graph's text output). Capped to 8 KiB so a chatty graph doesn't
  # bloat the transcript.
  if [[ -s "$transcript.stdout" ]]; then
    local content
    content="$(head -c 8192 "$transcript.stdout" | jq -Rs . 2>/dev/null || printf '""')"
    _jsonl_event "{\"event\":\"step\",\"type\":\"stdout\",\"content\":$content,\"ts\":\"$(_now_iso)\"}" >> "$transcript"
  fi
  if [[ -s "$transcript.stderr" ]]; then
    local err_content
    err_content="$(head -c 4096 "$transcript.stderr" | jq -Rs . 2>/dev/null || printf '""')"
    _jsonl_event "{\"event\":\"step\",\"type\":\"stderr\",\"content\":$err_content,\"ts\":\"$(_now_iso)\"}" >> "$transcript"
  fi

  rm -f "$transcript.stdout" "$transcript.stderr"

  if [[ "$rc" != "0" ]]; then
    _jsonl_event "{\"event\":\"error\",\"content\":\"graph exited $rc after ${elapsed}s\",\"ts\":\"$(_now_iso)\"}" >> "$transcript"
    return "$rc"
  fi

  _jsonl_event "{\"event\":\"result\",\"elapsed_seconds\":$elapsed,\"ts\":\"$(_now_iso)\"}" >> "$transcript"
  return 0
}

# --- fingerprint -----------------------------------------------------------

# Usage: langgraph_node_fingerprint <module_path>
# Stable hash of the graph source. Combines:
#   - the entry-point module file (always)
#   - <workdir>/tools/*.py            (optional, for tool modules)
#   - <workdir>/prompt_template_*.txt (optional)
#   - bodies of @tool-decorated top-level functions (adjacency check:
#     a `def` only counts if the immediately preceding line is `@tool`).
#
# Known limitations (documented in docs/runners.md):
#   - Multi-line decorators (e.g. `@tool(\n  ...\n)`) won't be detected.
#   - Class-based tools and conditionally-defined tools are out of scope.
# On any error, prints empty string and exits 0 so the manifest stays
# valid (the alternative — failing the whole run for a fingerprint glitch
# — is worse).
langgraph_node_fingerprint() {
  local module_path="${1:-}"
  if [[ -z "$module_path" ]] || [[ ! -f "$module_path" ]]; then
    printf '%s\n' "no-module"
    return 0
  fi

  local workdir
  workdir="$(dirname "$module_path")"

  # Collect files to hash, one path per line. Each line is sha256summed
  # individually and the concatenated output is then re-hashed so the
  # final fingerprint is a single hex string.
  local hash_input=""
  hash_input+="$(sha256sum "$module_path" 2>/dev/null)"$'\n'

  # Optional tool modules and prompt templates
  for f in "$workdir"/tools/*.py; do
    [[ -f "$f" ]] && hash_input+="$(sha256sum "$f" 2>/dev/null)"$'\n'
  done
  for f in "$workdir"/prompt_template_*.txt; do
    [[ -f "$f" ]] && hash_input+="$(sha256sum "$f" 2>/dev/null)"$'\n'
  done

  # @tool-decorated function bodies. Grep for the @tool marker with
  # one preceding context line (the `def`) so we capture each function
  # body. We hash the marker+def line+the next line (the body) so a
  # mutation to the function body flips the fingerprint even if the
  # decorator+signature stay the same.
  local tool_bodies
  tool_bodies="$(grep -B1 -A2 -E '^@tool' "$module_path" "$workdir"/tools/*.py 2>/dev/null | sha256sum 2>/dev/null || true)"
  hash_input+="${tool_bodies}"$'\n'

  printf '%s\n' "$hash_input" | sha256sum | cut -d' ' -f1
  return 0
}

# --- teardown --------------------------------------------------------------

# Usage: langgraph_node_teardown <workdir>
# Removes the venv unless EVAL_VENV_CACHE=1. Idempotent (rm -rf is).
langgraph_node_teardown() {
  local workdir="${1:-}"
  if [[ "${EVAL_VENV_CACHE:-0}" == "1" ]]; then
    echo "[langgraph-node] teardown:cache-preserved workdir=$workdir" >&2
    return 0
  fi
  local venv_dir="${EVAL_VENV_DIR:-$workdir/.venv}"
  if [[ -d "$venv_dir" ]]; then
    rm -rf "$venv_dir"
    echo "[langgraph-node] teardown:removed venv=$venv_dir" >&2
  else
    echo "[langgraph-node] teardown:no-op venv absent ($venv_dir)" >&2
  fi
  return 0
}

# --- CLI guard -------------------------------------------------------------
# Allows direct invocation: `bash langgraph-node.sh <sub> <args>`.
# When sourced (rare; only for the dispatch tests), the guard is a no-op.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  cmd="${1:-}"
  shift || true
  case "$cmd" in
    prepare)
      langgraph_node_prepare "$@"
      ;;
    spawn)
      langgraph_node_spawn "$@"
      ;;
    fingerprint)
      langgraph_node_fingerprint "$@"
      ;;
    teardown)
      langgraph_node_teardown "$@"
      ;;
    *)
      echo "langgraph-node.sh: unknown subcommand '$cmd' (expected: prepare|spawn|fingerprint|teardown)" >&2
      exit 2
      ;;
  esac
fi
