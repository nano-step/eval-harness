#!/usr/bin/env bash
set -euo pipefail

if ! declare -F resolve_skills_root >/dev/null; then
  _CFG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  source "$_CFG_DIR/skills_root.sh"
fi

resolve_project_config() {
  if [[ -n "${EVAL_HARNESS_CONFIG:-}" && -f "${EVAL_HARNESS_CONFIG}" ]]; then
    printf '%s\n' "${EVAL_HARNESS_CONFIG}"
    return 0
  fi
  local dir
  dir="$(pwd)"
  while [[ "$dir" != "/" && -n "$dir" ]]; do
    if [[ -f "$dir/.opencode/eval-harness.yaml" ]]; then
      printf '%s\n' "$dir/.opencode/eval-harness.yaml"
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  printf '\n'
}

apply_project_config() {
  local cfg
  cfg="$(resolve_project_config)"
  [[ -z "$cfg" || ! -f "$cfg" ]] && return 0

  local v
  v="$(yq -r '.model // ""' "$cfg" 2>/dev/null || echo "")"
  [[ -n "$v" && -z "${EVAL_MODEL:-}" ]] && export EVAL_MODEL="$v"

  v="$(yq -r '.budget_usd // ""' "$cfg" 2>/dev/null || echo "")"
  [[ -n "$v" && -z "${EVAL_BUDGET_USD:-}" ]] && export EVAL_BUDGET_USD="$v"

  v="$(yq -r '.max_seconds // ""' "$cfg" 2>/dev/null || echo "")"
  [[ -n "$v" && -z "${EVAL_MAX_SECONDS:-}" ]] && export EVAL_MAX_SECONDS="$v"

  v="$(yq -r '.skills_root // ""' "$cfg" 2>/dev/null || echo "")"
  [[ -n "$v" && -z "${OPENCODE_SKILLS_ROOT:-}" ]] && export OPENCODE_SKILLS_ROOT="$v"

  v="$(yq -r '.llm_judge.model // ""' "$cfg" 2>/dev/null || echo "")"
  [[ -n "$v" && -z "${EVAL_LLM_JUDGE_MODEL:-}" ]] && export EVAL_LLM_JUDGE_MODEL="$v"

  return 0
}

export -f resolve_project_config apply_project_config

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-}" in
    resolve) resolve_project_config ;;
    apply)   apply_project_config; env | grep -E '^(EVAL_|OPENCODE_SKILLS_ROOT)' | sort ;;
    *) echo "usage: config.sh {resolve|apply}" >&2; exit 2 ;;
  esac
fi
