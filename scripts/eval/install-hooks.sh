#!/usr/bin/env bash
# install-hooks.sh — wire pre-push into a git repo

set -euo pipefail

REPO_ROOT="${1:-$(pwd)}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ ! -d "$REPO_ROOT/.git" ]]; then
  echo "error: $REPO_ROOT is not a git repo" >&2
  exit 2
fi

GIT_HOOKS_DIR="$REPO_ROOT/.git/hooks"
mkdir -p "$GIT_HOOKS_DIR"

target="$GIT_HOOKS_DIR/pre-push"
source="$SCRIPT_DIR/hooks/pre-push"

if [[ -f "$target" ]] && ! grep -q "eval-harness" "$target" 2>/dev/null; then
  backup="$target.backup.$(date +%s)"
  mv "$target" "$backup"
  echo "[eval-harness] backed up existing pre-push to: $backup"
fi

cp "$source" "$target"
chmod +x "$target"
echo "[eval-harness] installed pre-push hook: $target"
