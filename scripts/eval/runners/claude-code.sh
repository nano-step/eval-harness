#!/usr/bin/env bash
# runners/claude-code.sh — adapter for the local Claude Code CLI (`claude`).
# Runner contract (docs/runners.md): prepare | spawn | fingerprint | teardown.
#
#   spawn <workdir> <runner_config_json> <transcript> <prompt>
#     (cd <workdir>) claude -p --output-format text --no-session-persistence [--model <m>]
#     with the prompt on stdin
#
# runner_config: {"model": "<claude model alias or id>"} (optional). Precedence: EVAL_AB_MODEL_OVERRIDE,
# then EVAL_CASE_MODEL (both set by run.sh), then runner_config.model; the opencode default is never forwarded.
# Claude Code uses its own native login/config and workspace-trust settings; the
# harness never passes a permission-bypass flag. It is a trusted process, not a
# sandbox: tools it is allowed to use by the user's own settings may run.
# Shared behaviour (stdin prompt, timeout, transcript event, fail-closed): lib/agent_cli.sh.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/agent_cli.sh"

AGENT_CLI_RUNNER="claude-code"
AGENT_CLI_BIN="claude"

# Usage: agent_cli_build_args <abs_workdir> <model_or_empty>
# The working directory is the process cwd (set by lib/agent_cli.sh), so $1 is unused.
agent_cli_build_args() {
  AGENT_CLI_ARGS=(-p --output-format text --no-session-persistence)
  if [[ -n "$2" ]]; then
    AGENT_CLI_ARGS=("${AGENT_CLI_ARGS[@]}" --model "$2")
  fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  rc=0
  agent_cli_main "$@" || rc=$?
  exit "$rc"
fi
