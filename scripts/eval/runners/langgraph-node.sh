#!/usr/bin/env bash
# runners/langgraph-node.sh — STUB for U1. Real implementation lands in U2.
#
# Contract: 4 subcommands, each with its own arg shape. The full spec
# lives in docs/runners.md. U2 implements each subcommand against
# LangGraph + the opencode JSONL transcript schema.
#
#   prepare <workdir>                  — set up venv, install deps
#   spawn <workdir> <input> <output> <transcript>
#                                      — invoke graph, capture transcript
#   fingerprint <module_path>          — emit a stable fingerprint string
#   teardown <workdir>                 — clean up venv
#
# U1 stub: each subcommand echoes its args to stderr and writes a minimal
# transcript event so the wiring can be exercised end-to-end without
# pulling in LangGraph or python. U2 replaces each branch.

set -euo pipefail

cmd="${1:-}"
shift || true

case "$cmd" in
  prepare)
    workdir="${1:-}"
    echo "[langgraph-node] STUB prepare workdir=$workdir" >&2
    exit 0
    ;;
  spawn)
    workdir="${1:-}"; input="${2:-}"; output="${3:-}"; transcript="${4:-}"
    echo "[langgraph-node] STUB spawn workdir=$workdir input=$input output=$output transcript=$transcript" >&2
    if [[ -n "$transcript" ]]; then
      printf '{"event":"stub","subcommand":"spawn","note":"U1 stub; U2 implements real LangGraph invoke"}\n' > "$transcript"
    fi
    exit 0
    ;;
  fingerprint)
    module="${1:-}"
    echo "[langgraph-node] STUB fingerprint module=$module" >&2
    # A stable stub fingerprint so the manifest is non-empty.
    echo "stub-langgraph-fingerprint"
    exit 0
    ;;
  teardown)
    workdir="${1:-}"
    echo "[langgraph-node] STUB teardown workdir=$workdir" >&2
    exit 0
    ;;
  *)
    echo "langgraph-node.sh: unknown subcommand '$cmd' (expected: prepare|spawn|fingerprint|teardown)" >&2
    exit 2
    ;;
esac
