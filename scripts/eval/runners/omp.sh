#!/usr/bin/env bash
# runners/omp.sh — adapter for the local `omp` (Oh My Pi) coding agent.
# Runner contract (docs/runners.md): prepare | spawn | fingerprint | teardown.
#
#   spawn <workdir> <runner_config_json> <transcript> <prompt>
#     omp -p --mode text --no-session --cwd <workdir> [--model <m>]   (prompt on stdin)
#
# runner_config: {"model": "<omp model pattern>"} (optional). Precedence: EVAL_AB_MODEL_OVERRIDE,
# then EVAL_CASE_MODEL (both set by run.sh), then runner_config.model; the opencode default is never forwarded.
# omp uses its own native login/config and trusted-project settings; the harness
# adds no auto-approval flag. omp is a trusted process, not a sandbox.
# Shared behaviour (stdin prompt, timeout, transcript event, fail-closed): lib/agent_cli.sh.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/agent_cli.sh"

AGENT_CLI_RUNNER="omp"
AGENT_CLI_BIN="omp"

# Usage: agent_cli_build_args <abs_workdir> <model_or_empty>
agent_cli_build_args() {
  AGENT_CLI_ARGS=(-p --mode text --no-session --cwd "$1")
  if [[ -n "$2" ]]; then
    AGENT_CLI_ARGS=("${AGENT_CLI_ARGS[@]}" --model "$2")
  fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  rc=0
  agent_cli_main "$@" || rc=$?
  exit "$rc"
fi
