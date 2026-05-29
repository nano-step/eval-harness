#!/usr/bin/env bash
# lib/skills_root.sh — resolve OPENCODE_SKILLS_ROOT with auto-detection.
#
# Resolution order (first match wins):
#   1. $OPENCODE_SKILLS_ROOT if explicitly set and non-empty
#   2. Walk up from $PWD looking for a `.opencode/skills/` directory
#      (lets repo-local skills dirs be discovered automatically)
#   3. Fallback to $HOME/.config/opencode/skills (user-global install)
#
# Output: prints the resolved absolute path on stdout. Always exits 0.
# Side effect: none. (We do NOT export — caller chooses how to use it.)

set -euo pipefail

resolve_skills_root() {
  # 1. Explicit env var wins.
  if [[ -n "${OPENCODE_SKILLS_ROOT:-}" ]]; then
    printf '%s\n' "$OPENCODE_SKILLS_ROOT"
    return 0
  fi

  # 2. Walk up from cwd looking for .opencode/skills/.
  local dir
  dir="$(pwd)"
  while [[ "$dir" != "/" && -n "$dir" ]]; do
    if [[ -d "$dir/.opencode/skills" ]]; then
      printf '%s\n' "$dir/.opencode/skills"
      return 0
    fi
    dir="$(dirname "$dir")"
  done

  # 3. User-global fallback.
  printf '%s\n' "${HOME}/.config/opencode/skills"
}

export -f resolve_skills_root

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  resolve_skills_root
fi
