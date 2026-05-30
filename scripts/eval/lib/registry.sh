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

registry_discover_workspace() {
  local root="$1"; local filter="$2"; local max_depth="${3:-3}"
  [[ -d "$root" ]] || { echo "registry_discover_workspace: root '$root' not a directory" >&2; return 2; }
  root="$(cd "$root" && pwd)"

  find "$root" -maxdepth "$max_depth" -name .git -prune 2>/dev/null \
    | while read -r git_marker; do
        local repo_dir; repo_dir="$(dirname "$git_marker")"
        local name; name="$(basename "$repo_dir")"
        case "$filter" in
          all)
            printf '%s\n' "$name"
            ;;
          skills)
            if [[ -d "$repo_dir/.opencode/skills" ]] && \
               find "$repo_dir/.opencode/skills" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | grep -q .; then
              printf '%s\n' "$name"
            fi
            ;;
          cases)
            if find "$repo_dir/.opencode/skills" -path '*/evals/cases/*.yaml' -type f 2>/dev/null | grep -q .; then
              printf '%s\n' "$name"
            fi
            ;;
          *)
            echo "registry_discover_workspace: unknown filter '$filter' (use all|skills|cases)" >&2
            return 2
            ;;
        esac
      done | sort -u
}

registry_enable_workspace() {
  local root="${EVAL_WORKSPACE_ROOT:-$(pwd)}"
  local filter="skills"
  local dry_run=0
  local max_depth=3

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --root=*)        root="${1#*=}" ;;
      --filter=*)      filter="${1#*=}" ;;
      --max-depth=*)   max_depth="${1#*=}" ;;
      --dry-run)       dry_run=1 ;;
      -h|--help)
        cat <<'USAGE'
Usage: registry.sh enable-workspace [options]
Options:
  --root=PATH        workspace root to scan (default: cwd)
  --filter=FILTER    which repos to include:
                       all     — every .git repo found
                       skills  — repos with .opencode/skills/<X>/ (default)
                       cases   — repos with .opencode/skills/<X>/evals/cases/*.yaml
  --max-depth=N      find -maxdepth (default: 3)
  --dry-run          print plan; don't write registry
USAGE
        return 0
        ;;
      *) echo "enable-workspace: unknown arg '$1'" >&2; return 2 ;;
    esac
    shift
  done

  case "$filter" in all|skills|cases) ;; *)
    echo "enable-workspace: invalid --filter='$filter' (use all|skills|cases)" >&2
    return 2
    ;;
  esac

  if ! [[ "$max_depth" =~ ^[1-9][0-9]*$ ]]; then
    echo "enable-workspace: --max-depth must be a positive integer, got '$max_depth'" >&2
    return 2
  fi

  local discovered
  discovered="$(registry_discover_workspace "$root" "$filter" "$max_depth")" || return $?

  if [[ -z "$discovered" ]]; then
    echo "[registry] no repos matched filter=$filter under $root (max-depth=$max_depth)" >&2
    return 0
  fi

  local discovered_count
  discovered_count="$(printf '%s\n' "$discovered" | wc -l | tr -d ' ')"

  echo "[registry] discovered $discovered_count repo(s) under $root (filter=$filter):" >&2
  printf '  %s\n' $discovered >&2

  if [[ "$dry_run" == "1" ]]; then
    echo "[registry] --dry-run: not writing" >&2
    return 0
  fi

  local path; path="$(registry_init)"
  local current
  current="$(yq -o=json '.enabled_repos // []' "$path" 2>/dev/null || echo '[]')"

  local discovered_json
  discovered_json="$(printf '%s\n' "$discovered" | jq -R . | jq -s .)"

  local merged
  merged="$(jq -n --argjson cur "$current" --argjson new "$discovered_json" \
    '($cur + $new) | unique')"

  local before_count after_count added_count
  before_count="$(echo "$current" | jq 'length')"
  after_count="$(echo "$merged" | jq 'length')"
  added_count="$(( after_count - before_count ))"

  local tmp; tmp="$(mktemp)"
  jq -n --argjson list "$merged" '{schema_version: 1, enabled_repos: $list}' > "$tmp"
  mv "$tmp" "$path"

  echo "[registry] enabled $added_count new repo(s); registry now has $after_count total" >&2
  echo "[registry] $path"
}

export -f registry_path registry_init registry_enable registry_disable registry_list \
          registry_is_enabled repo_name_from_path registry_discover_workspace \
          registry_enable_workspace

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-}" in
    init)               registry_init ;;
    enable)             shift; registry_enable "$@" ;;
    enable-workspace)   shift; registry_enable_workspace "$@" ;;
    disable)            shift; registry_disable "$@" ;;
    list)               registry_list ;;
    is-enabled)         shift; if registry_is_enabled "$@"; then echo enabled; else echo disabled; exit 1; fi ;;
    repo-name)          shift; repo_name_from_path "$@" ;;
    discover)           shift; registry_discover_workspace "${1:-$(pwd)}" "${2:-skills}" "${3:-3}" ;;
    *) cat <<'USAGE' >&2
usage: registry.sh <command> [args]

commands:
  init                              ensure registry file exists
  enable <repo>                     add one repo to the registry
  enable-workspace [opts]           bulk-enable all repos under a workspace root
                                    (use --help on this subcommand for options)
  disable <repo>                    remove one repo
  list                              print enabled repos, one per line
  is-enabled <repo>                 exit 0 if enabled, 1 otherwise
  repo-name [path]                  print repo name (walks up for .git)
  discover <root> [filter] [depth]  print repos that WOULD be enabled (no write)
USAGE
       exit 2
       ;;
  esac
fi
