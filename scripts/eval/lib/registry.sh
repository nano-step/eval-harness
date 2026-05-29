#!/usr/bin/env bash
set -euo pipefail

_REG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ! command -v yq >/dev/null 2>&1; then
  source "$_REG_DIR/yq-shim.sh"
fi

DEFAULT_REGISTRY="${EVAL_HARNESS_REGISTRY:-$HOME/.config/opencode/eval-harness/registry.yaml}"

registry_path() { printf '%s\n' "$DEFAULT_REGISTRY"; }

registry_init() {
  local path; path="$(registry_path)"
  mkdir -p "$(dirname "$path")"
  if [[ ! -f "$path" ]]; then
    cat > "$path" <<YAML
schema_version: 1
enabled_repos: []
YAML
  fi
  printf '%s\n' "$path"
}

registry_enable() {
  local repo="$1"
  [[ -z "$repo" ]] && { echo "registry_enable: repo required" >&2; return 2; }
  local path; path="$(registry_init)"
  local current
  current="$(yq -o=json '.enabled_repos // []' "$path" 2>/dev/null || echo '[]')"
  local updated
  updated="$(jq --arg r "$repo" '. + [$r] | unique' <<<"$current")"
  local tmp; tmp="$(mktemp)"
  jq -n --argjson list "$updated" '{schema_version: 1, enabled_repos: $list}' > "$tmp"
  mv "$tmp" "$path"
  echo "[registry] enabled: $repo"
}

registry_disable() {
  local repo="$1"
  [[ -z "$repo" ]] && { echo "registry_disable: repo required" >&2; return 2; }
  local path; path="$(registry_init)"
  local updated
  updated="$(yq -o=json '.enabled_repos // []' "$path" | jq --arg r "$repo" 'map(select(. != $r))')"
  local tmp; tmp="$(mktemp)"
  jq -n --argjson list "$updated" '{schema_version: 1, enabled_repos: $list}' > "$tmp"
  mv "$tmp" "$path"
  echo "[registry] disabled: $repo"
}

registry_list() {
  local path; path="$(registry_path)"
  if [[ ! -f "$path" ]]; then
    echo "[registry] empty (no $path)"
    return 0
  fi
  yq -r '.enabled_repos[]?' "$path"
}

registry_is_enabled() {
  local repo="$1"
  [[ -z "$repo" ]] && return 1
  local path; path="$(registry_path)"
  [[ -f "$path" ]] || return 1
  yq -r '.enabled_repos[]?' "$path" | grep -Fxq "$repo"
}

repo_name_from_path() {
  local p="${1:-$(pwd)}"
  while [[ "$p" != "/" && -n "$p" ]]; do
    if [[ -d "$p/.git" || -f "$p/.git" ]]; then
      basename "$p"; return 0
    fi
    p="$(dirname "$p")"
  done
  basename "${1:-$(pwd)}"
}

export -f registry_path registry_init registry_enable registry_disable registry_list registry_is_enabled repo_name_from_path

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-}" in
    init)        registry_init ;;
    enable)      shift; registry_enable "$@" ;;
    disable)     shift; registry_disable "$@" ;;
    list)        registry_list ;;
    is-enabled)  shift; if registry_is_enabled "$@"; then echo enabled; else echo disabled; exit 1; fi ;;
    repo-name)   shift; repo_name_from_path "$@" ;;
    *) echo "usage: registry.sh {init|enable <repo>|disable <repo>|list|is-enabled <repo>|repo-name [path]}" >&2; exit 2 ;;
  esac
fi
