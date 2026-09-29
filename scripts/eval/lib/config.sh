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

# pre_push_should_fire <branch> returns 0 when the branch is included by project policy.
pre_push_should_fire() {
  local branch="$1" cfg
  cfg="$(resolve_project_config)"
  [[ -z "$cfg" || ! -f "$cfg" ]] && return 0
  local include_raw exclude_raw
  include_raw="$(yq -r '.pre_push.branches.include[]?' "$cfg" 2>/dev/null || true)"
  exclude_raw="$(yq -r '.pre_push.branches.exclude[]?' "$cfg" 2>/dev/null || true)"
  local includes=() excludes=() g
  while IFS= read -r g; do [[ -n "$g" ]] && includes+=("$g"); done <<< "$include_raw"
  while IFS= read -r g; do [[ -n "$g" ]] && excludes+=("$g"); done <<< "$exclude_raw"
  if [[ ${#includes[@]} -gt 0 ]]; then
    for g in "${includes[@]}"; do
      case "$branch" in $g) return 0 ;; esac
    done
    return 1
  fi
  if [[ ${#excludes[@]} -gt 0 ]]; then
    for g in "${excludes[@]}"; do
      case "$branch" in $g) return 1 ;; esac
    done
  fi
  return 0
}

export -f resolve_project_config apply_project_config pre_push_should_fire

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-}" in
    resolve) resolve_project_config ;;
    apply) apply_project_config; env | grep -E '^(EVAL_|OPENCODE_SKILLS_ROOT)' | sort ;;
    should_fire) pre_push_should_fire "${2:-}" && echo fire || echo skip ;;
    *) echo "usage: config.sh {resolve|apply|should_fire <branch>}" >&2; exit 2 ;;
  esac
fi
