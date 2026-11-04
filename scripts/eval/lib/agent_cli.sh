#!/usr/bin/env bash
# lib/agent_cli.sh — shared implementation for adapters that drive a local,
# natively-authenticated coding-agent CLI (runners/omp.sh, claude-code.sh,
# codex.sh). The runner contract (4 subcommands) is dispatched by lib/runner.sh
# as `bash <runner>.sh <sub> <args>`:
#
#   prepare     <workdir> [<runner_config_json>]   validate config, check the CLI is on PATH
#   spawn       <workdir> <runner_config_json> <transcript> <prompt>
#   fingerprint <workdir> [<runner_config_json>]   prints "unknown" (no trustworthy identity)
#   teardown    <workdir>                          no-op (nothing is created outside the workdir)
#
# A runner script sets AGENT_CLI_RUNNER, AGENT_CLI_BIN and defines
#   agent_cli_build_args <abs_workdir> <model_or_empty>
# which fills the AGENT_CLI_ARGS array (never empty). Everything else lives here.
#
# Behaviour (spawn):
#   * The prompt is delivered on STDIN from a file holding its exact bytes. It is
#     never an argv element, so a prompt starting with '-' (or '@' for omp) cannot
#     be parsed as an option / file attachment, multi-line prompts are preserved
#     exactly, and nothing is ever eval'd or shell-expanded.
#   * The CLI runs as `run_with_timeout $EVAL_MAX_SECONDS <abs-path> args...` in a
#     subshell cd'd to the workdir. The binary is resolved to an absolute path
#     BEFORE the cd, so a fixture executable cannot shadow it.
#   * Model: EVAL_AB_MODEL_OVERRIDE, else EVAL_CASE_MODEL (both set by run.sh), else
#     runner_config.model. EVAL_MODEL / OPENCODE_MODEL (opencode defaults) are
#     deliberately ignored. No model flag when none of the three is set.
#   * stdout (the agent's final response) becomes ONE normalized JSON event line in
#     <transcript>:  {"event":"result","type":"assistant","runner":...,"content":...,"ts":...}
#     No usage/cost fields are manufactured: score/diff treat the run as "usage
#     unavailable". stderr is diagnostics only, written to <transcript>.err.
#   * Any failure (non-zero exit, 124 timeout, bad config, missing CLI, or exit 0 with
#     EMPTY stdout) leaves an EMPTY transcript and returns the CLI's exit code (2 = bad
#     input, 13 = no/unencodable response, 127 = CLI not found), so run.sh records an
#     ERROR, never a score.
#   * spawn writes NOTHING to stdout (run.sh captures stdout as the exit code).
#
# SECURITY: the CLI is a TRUSTED process, not a sandbox. It uses the user's own
# native login/config (HOME is untouched, credentials are never copied), may run
# tools in the workdir according to that CLI's own approval/sandbox settings, and
# may need the workdir to be trusted in the user's config. This library adds no
# auto-approval flag and never weakens a CLI's sandbox.

set -euo pipefail

_AGENT_CLI_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_AGENT_CLI_LIB_DIR/portable.sh"

AGENT_CLI_RUNNER="${AGENT_CLI_RUNNER:-agent-cli}"
AGENT_CLI_BIN="${AGENT_CLI_BIN:-}"
AGENT_CLI_MODEL=""
AGENT_CLI_ARGS=()

_agent_cli_err() { printf '[eval-harness] runner=%s: %s\n' "$AGENT_CLI_RUNNER" "$*" >&2; }

# Usage: _agent_cli_valid_model <value>
# Non-empty, <= 200 chars, no leading '-' (cannot become a flag), no whitespace/control chars.
_agent_cli_valid_model() {
  local m="$1"
  [[ -n "$m" && ${#m} -le 200 ]] || return 1
  [[ "$m" != -* ]] || return 1
  [[ ! "$m" =~ [[:cntrl:][:space:]] ]] || return 1
  return 0
}

# Usage: agent_cli_resolve_model <runner_config_json>
# Sets AGENT_CLI_MODEL (possibly empty). Returns 2 on invalid config/model.
# runner_config accepts exactly one key, "model"; any other key is rejected so a
# typo can never silently run the CLI with its default model. The config is
# validated even when an env override wins.
agent_cli_resolve_model() {
  local config="${1-}" kind unknown ok cfg_model=""
  AGENT_CLI_MODEL=""
  if [[ -n "${config//[[:space:]]/}" ]]; then
    if ! printf '%s' "$config" | jq -e 'type == "object"' >/dev/null 2>&1; then
      _agent_cli_err "runner_config must be a JSON object"
      return 2
    fi
    unknown="$(printf '%s' "$config" | jq -r '[keys[] | select(. != "model")] | join(",")')"
    if [[ -n "$unknown" ]]; then
      _agent_cli_err "unsupported runner_config key(s): $unknown (only 'model' is supported)"
      return 2
    fi
    kind="$(printf '%s' "$config" | jq -r '.model | type')"
    case "$kind" in
      null) ;;
      string)
        ok="$(printf '%s' "$config" | jq -r '.model | (length > 0 and length <= 200 and ((explode | any(. <= 32 or . == 127)) | not) and (startswith("-") | not))')"
        if [[ "$ok" != "true" ]]; then
          _agent_cli_err "runner_config.model is invalid (must be non-empty, not start with '-', no whitespace/control characters)"
          return 2
        fi
        cfg_model="$(printf '%s' "$config" | jq -r '.model')"
        ;;
      *)
        _agent_cli_err "runner_config.model must be a string"
        return 2
        ;;
    esac
  fi
  # Precedence: EVAL_AB_MODEL_OVERRIDE (A/B run) > EVAL_CASE_MODEL (run.sh: case `model:`)
  # > runner_config.model. A/B overrides and per-case models are chosen by run.sh on purpose.
  local env_name env_val
  for env_name in EVAL_AB_MODEL_OVERRIDE EVAL_CASE_MODEL; do
    env_val="$(printenv "$env_name" 2>/dev/null || true)"
    [[ -n "$env_val" ]] || continue
    if ! _agent_cli_valid_model "$env_val"; then
      _agent_cli_err "$env_name is invalid (must not start with '-' or contain whitespace/control characters)"
      return 2
    fi
    AGENT_CLI_MODEL="$env_val"
    break
  done
  [[ -n "$AGENT_CLI_MODEL" ]] || AGENT_CLI_MODEL="$cfg_model"
  return 0
}

# Usage: _agent_cli_resolve_bin ; prints the absolute path of AGENT_CLI_BIN.
# A relative PATH hit (e.g. PATH containing ".") is refused: it could be a fixture.
_agent_cli_resolve_bin() {
  local p
  p="$(type -P "$AGENT_CLI_BIN" 2>/dev/null || true)"
  if [[ -z "$p" ]]; then
    _agent_cli_err "CLI '$AGENT_CLI_BIN' not found on PATH (install it and log in with its own login flow)"
    return 127
  fi
  if [[ "$p" != /* ]]; then
    _agent_cli_err "CLI '$AGENT_CLI_BIN' resolved to a relative path '$p'; refusing (fix PATH)"
    return 127
  fi
  printf '%s\n' "$p"
}

_agent_cli_abs_dir() { (cd "$1" 2>/dev/null && pwd -P); }

# --- prepare / fingerprint / teardown ---------------------------------------

# Usage: agent_cli_prepare <workdir> [<runner_config_json>]
agent_cli_prepare() {
  local workdir="${1-}" config="${2-}" rc=0
  if ! command -v jq >/dev/null 2>&1; then _agent_cli_err "jq is required on PATH"; return 127; fi
  if [[ -n "$workdir" && ! -d "$workdir" ]]; then _agent_cli_err "workdir not found: $workdir"; return 2; fi
  agent_cli_resolve_model "$config" || return $?
  _agent_cli_resolve_bin >/dev/null || rc=$?
  return "$rc"
}

# No trustworthy identity exists without invoking the CLI (and a version string
# says nothing about the user's native config/model), so report "unknown".
agent_cli_fingerprint() { printf 'unknown\n'; }

# --- spawn -------------------------------------------------------------------

# Usage: agent_cli_spawn <workdir> <runner_config_json> <transcript> <prompt>
agent_cli_spawn() {
  local tmp rc=0
  if ! tmp="$(mktemp -d "${TMPDIR:-/tmp}/eval-agent-cli.XXXXXX")"; then
    _agent_cli_err "cannot create a temporary directory"
    return 13
  fi
  _agent_cli_spawn_inner "$tmp" "$@" || rc=$?
  rm -rf "$tmp"
  return "$rc"
}

_agent_cli_spawn_inner() {
  local tmp="$1"; shift
  local workdir="${1-}" config="${2-}" transcript="${3-}" prompt="${4-}"
  local max_seconds="${EVAL_MAX_SECONDS:-180}" bin_path abs_wd ts rc=0

  [[ -n "$transcript" ]] || { _agent_cli_err "spawn: transcript path is required"; return 2; }
  [[ "$transcript" == /* ]] || transcript="$PWD/$transcript"
  # Fail closed: nothing from an earlier execution may survive as evidence.
  if ! { : > "$transcript" && : > "$transcript.err"; } 2>/dev/null; then
    _agent_cli_err "spawn: cannot write transcript '$transcript'"
    return 2
  fi

  if ! command -v jq >/dev/null 2>&1; then _agent_cli_err "jq is required on PATH"; return 127; fi
  if [[ -z "$workdir" ]] || ! abs_wd="$(_agent_cli_abs_dir "$workdir")"; then
    _agent_cli_err "spawn: workdir not found: ${workdir:-<empty>}"
    return 2
  fi
  if [[ -z "$prompt" ]]; then _agent_cli_err "spawn: prompt is required"; return 2; fi
  if [[ ! "$max_seconds" =~ ^[0-9]+$ ]] || (( 10#$max_seconds < 1 )); then
    _agent_cli_err "EVAL_MAX_SECONDS must be a positive integer (got '$max_seconds')"
    return 2
  fi
  agent_cli_resolve_model "$config" || return $?
  bin_path="$(_agent_cli_resolve_bin)" || return $?

  AGENT_CLI_ARGS=()
  agent_cli_build_args "$abs_wd" "$AGENT_CLI_MODEL"

  # Exact prompt bytes; printf '%s' adds no trailing newline.
  printf '%s' "$prompt" > "$tmp/prompt"

  (
    cd "$abs_wd" || exit 2
    export EVAL_HARNESS_RUNNING=1 OPENCODE_EVAL_MODE=1
    run_with_timeout "$max_seconds" "$bin_path" "${AGENT_CLI_ARGS[@]}" \
      < "$tmp/prompt" > "$tmp/stdout" 2>> "$transcript.err"
  ) || rc=$?

  if (( rc != 0 )); then
    {
      printf '[%s] exited %s%s\n' "$AGENT_CLI_RUNNER" "$rc" "$([[ $rc -eq 124 ]] && printf ' (timeout after %ss)' "$max_seconds")"
      if [[ -s "$tmp/stdout" ]]; then
        printf '[%s] stdout before failure (first 4096 bytes):\n' "$AGENT_CLI_RUNNER"
        head -c 4096 "$tmp/stdout"
        printf '\n'
      fi
    } >> "$transcript.err" 2>/dev/null || true
    : > "$transcript"
    return "$rc"
  fi

  # A zero-byte response is not evidence: a transcript-negative check (e.g. output_not_contains)
  # would falsely PASS on it. Treat it as a failed run with an empty transcript.
  if [[ ! -s "$tmp/stdout" ]]; then
    _agent_cli_err "CLI exited 0 but produced no stdout (no response evidence); failing"
    printf '[%s] exited 0 with empty stdout\n' "$AGENT_CLI_RUNNER" >> "$transcript.err" 2>/dev/null || true
    : > "$transcript"
    return 13
  fi

  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  if ! jq -cn --rawfile content "$tmp/stdout" --arg runner "$AGENT_CLI_RUNNER" \
        --arg model "$AGENT_CLI_MODEL" --arg ts "$ts" \
        '{event:"result",type:"assistant",runner:$runner,content:$content,ts:$ts}
         + (if $model == "" then {} else {requested_model:$model} end)' \
        > "$tmp/event" 2>> "$transcript.err" || [[ ! -s "$tmp/event" ]]; then
    _agent_cli_err "could not encode the CLI response as JSON"
    : > "$transcript"
    return 13
  fi
  cat "$tmp/event" > "$transcript"
  return 0
}

# Usage: agent_cli_main <subcommand> [args...]
agent_cli_main() {
  local cmd="${1-}"
  shift || true
  case "$cmd" in
    prepare)     agent_cli_prepare "$@" ;;
    spawn)       agent_cli_spawn "$@" ;;
    fingerprint) agent_cli_fingerprint "$@" ;;
    teardown)    return 0 ;;
    *)
      _agent_cli_err "unknown subcommand '$cmd' (expected: prepare|spawn|fingerprint|teardown)"
      return 2
      ;;
  esac
}
