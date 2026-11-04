#!/usr/bin/env bash
# runners/codex.sh — adapter for the local Codex CLI (`codex exec`).
# Runner contract (docs/runners.md): prepare | spawn | fingerprint | teardown.
#
#   spawn <workdir> <runner_config_json> <transcript> <prompt>
#     codex exec --skip-git-repo-check --sandbox workspace-write -C <workdir> [-m <m>] -
#     The trailing "-" makes codex read the prompt from stdin (exact bytes).
#
# runner_config: {"model": "<codex model>"} (optional). Precedence: EVAL_AB_MODEL_OVERRIDE,
# then EVAL_CASE_MODEL (both set by run.sh), then runner_config.model; the opencode default is never forwarded.
# Codex uses its own native login/config. The harness selects Codex's own
# workspace-write sandbox and never forces bypass/danger-full-access; Codex is a
# trusted process, so treat this as the CLI's sandbox, not an eval-harness one.
# Shared behaviour (stdin prompt, timeout, transcript event, fail-closed): lib/agent_cli.sh.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/agent_cli.sh"

AGENT_CLI_RUNNER="codex"
AGENT_CLI_BIN="codex"

# Usage: agent_cli_build_args <abs_workdir> <model_or_empty>
agent_cli_build_args() {
  AGENT_CLI_ARGS=(exec --skip-git-repo-check --sandbox workspace-write -C "$1")
  if [[ -n "$2" ]]; then
    AGENT_CLI_ARGS=("${AGENT_CLI_ARGS[@]}" -m "$2")
  fi
  AGENT_CLI_ARGS=("${AGENT_CLI_ARGS[@]}" -)
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  rc=0
  agent_cli_main "$@" || rc=$?
  exit "$rc"
fi
