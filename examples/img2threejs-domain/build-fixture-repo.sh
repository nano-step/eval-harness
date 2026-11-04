#!/usr/bin/env bash
# Create an isolated, deterministic git repository; never runs target code or installs dependencies.
set -euo pipefail
self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
dest="${1:?usage: build-fixture-repo.sh NEW_DIRECTORY}"
if [[ -e "$dest" && -n "$(ls -A "$dest")" ]]; then echo 'destination must be empty' >&2; exit 2; fi
mkdir -p "$dest/src"
dest="$(cd "$dest" && pwd -P)"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME='ATD Fixture' GIT_AUTHOR_EMAIL='atd@example.invalid'
export GIT_COMMITTER_NAME='ATD Fixture' GIT_COMMITTER_EMAIL='atd@example.invalid'
export GIT_AUTHOR_DATE='2026-01-01T00:00:00Z' GIT_COMMITTER_DATE='2026-01-01T00:00:00Z'
git -C "$dest" -c core.hooksPath=/dev/null init -q -b baseline
cp "$self/src/scene.ts" "$dest/src/scene.ts"
cp "$self/package.json" "$self/package-lock.json" "$dest/"
git -C "$dest" -c core.hooksPath=/dev/null add src/scene.ts package.json package-lock.json
git -C "$dest" -c core.hooksPath=/dev/null -c commit.gpgsign=false commit -q -m 'deterministic Three.js fixture'
git -C "$dest" rev-parse HEAD
