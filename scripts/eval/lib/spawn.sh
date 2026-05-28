#!/usr/bin/env bash
# lib/spawn.sh — invoke opencode in a fully-sandboxed environment.
# Settled Decisions #9, #13: ephemeral HOME, OPENCODE_CONFIG_DIR, NANO_BRAIN_ROOT, cwd.
# OPENCODE_EVAL_MODE=1 set so skills can detect and refuse destructive ops.
#
# opencode 1.15.10 lacks --max-turns / --skills / --prompt-file flags.
# Compensations: timeout(1) wraps subprocess; skill-set pinned via ephemeral OPENCODE_CONFIG_DIR.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Usage: spawn_opencode <prompt> <workdir> <sandbox_dir> <transcript_out> [skills_to_load...]
# - prompt: the user message string
# - workdir: cwd for the opencode run (case fixtures already materialized here)
# - sandbox_dir: parent for ephemeral HOME / OPENCODE_CONFIG_DIR / NANO_BRAIN_ROOT
# - transcript_out: path to write the JSON-formatted transcript
# - skills_to_load: skill names to materialize into ephemeral OPENCODE_CONFIG_DIR
spawn_opencode() {
  local prompt="$1"
  local workdir="$2"
  local sandbox="$3"
  local transcript_out="$4"
  shift 4
  local skills_to_load=("$@")

  mkdir -p "$sandbox/home" "$sandbox/opencode/skills" "$sandbox/nano-brain"

  local real_skills_root="${OPENCODE_SKILLS_ROOT:-$HOME/.config/opencode/skills}"
  for skill in "${skills_to_load[@]}"; do
    if [[ -d "$real_skills_root/$skill" ]]; then
      cp -R "$real_skills_root/$skill" "$sandbox/opencode/skills/$skill"
    fi
  done

  local max_seconds="${EVAL_MAX_SECONDS:-180}"
  local model="${EVAL_MODEL:-${OPENCODE_MODEL:-anthropic/claude-3-5-haiku-latest}}"

  local exit_code=0
  (
    export HOME="$sandbox/home"
    export OPENCODE_CONFIG_DIR="$sandbox/opencode"
    export NANO_BRAIN_ROOT="$sandbox/nano-brain"
    export OPENCODE_EVAL_MODE=1
    export EVAL_HARNESS_RUNNING=1
    cd "$workdir"
    timeout "$max_seconds" opencode run \
      --model "$model" \
      --format json \
      --dir "$workdir" \
      "$prompt" > "$transcript_out" 2>"$transcript_out.err"
  ) || exit_code=$?

  echo "$exit_code"
}

# Usage: token_total <transcript_jsonl>
# Sums prompt_tokens + completion_tokens from opencode --format json events.
# Per Settled #17: tokens-based capture, not opencode's broken dollar telemetry.
token_total() {
  local transcript="$1"
  if [[ ! -s "$transcript" ]]; then echo 0; return 0; fi
  jq -s '
    [.[] | .. | objects | select(.usage?) | .usage |
     ((.input_tokens // .prompt_tokens // 0) + (.output_tokens // .completion_tokens // 0))]
    | add // 0
  ' "$transcript" 2>/dev/null || echo 0
}

export -f spawn_opencode token_total

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-}" in
    run)    shift; spawn_opencode "$@" ;;
    tokens) shift; token_total "$@" ;;
    *) echo "usage: spawn.sh {run <prompt> <workdir> <sandbox> <transcript_out> [skills...] | tokens <transcript>}" >&2; exit 2 ;;
  esac
fi
