#!/usr/bin/env bash
# build-fixture-repo.sh — create the isolated git repository used by the collision pilot.
#
# Usage: build-fixture-repo.sh <new-empty-dir>
#
# Commits, all with fixed identities and dates so the SHAs are reproducible from the same
# fixture bytes and git version:
#   baseline          the collision module plus its existing tests (no touching-edge case)
#   clean-change      baseline + patches/clean-change.patch        (behaviour-preserving refactor)
#   boundary-defect   baseline + patches/boundary-defect.patch     (touching edges reported as overlap)
#   zero-size-defect  baseline + patches/zero-size-defect.patch    (second rectangle's size ignored)
# Each non-baseline revision is a separate branch off the baseline, so no revision contains another
# revision's change. Prints one JSON object with the full SHAs on stdout. Nothing is installed,
# executed or fetched; node_modules is never created here.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="${1:-}"
if [[ -z "$DEST" ]]; then
  echo "usage: build-fixture-repo.sh <new-empty-dir>" >&2
  exit 2
fi
if [[ -e "$DEST" ]] && [[ -n "$(ls -A "$DEST" 2>/dev/null)" ]]; then
  echo "build-fixture-repo: refusing to use non-empty destination: $DEST" >&2
  exit 2
fi
mkdir -p "$DEST"
DEST="$(cd "$DEST" && pwd)"

# Isolate from user/system git configuration (hooks, signing, templates, attributes).
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME="ATD Pilot" GIT_AUTHOR_EMAIL="atd-pilot@example.invalid"
export GIT_COMMITTER_NAME="ATD Pilot" GIT_COMMITTER_EMAIL="atd-pilot@example.invalid"
export GIT_AUTHOR_DATE="2026-01-01T00:00:00Z" GIT_COMMITTER_DATE="2026-01-01T00:00:00Z"

g() { git -C "$DEST" -c commit.gpgsign=false -c core.hooksPath=/dev/null -c core.autocrlf=false "$@"; }

g init -q -b baseline
mkdir -p "$DEST/src" "$DEST/test"
for f in package.json package-lock.json SPEC.md vitest.config.ts src/collision.ts test/collision.test.ts; do
  cp "$SELF_DIR/$f" "$DEST/$f"
done
g add -A
g commit -q -m "baseline: rectangle collision module with existing tests"
BASE="$(g rev-parse HEAD)"

variant() {
  local branch="$1" patch="$2" message="$3"
  g checkout -q -b "$branch" "$BASE"
  g apply --whitespace=nowarn "$SELF_DIR/patches/$patch"
  g add -A
  g commit -q -m "$message"
  g rev-parse HEAD
}

CLEAN="$(variant clean-change clean-change.patch 'refactor: extract per-axis interval helper (no behaviour change)')"
BOUNDARY="$(variant boundary-defect boundary-defect.patch 'perf: relax x-axis comparison (injected boundary defect)')"
ZERO="$(variant zero-size-defect zero-size-defect.patch 'simplify: skip emptiness check of second rectangle (injected defect)')"
g checkout -q baseline

jq -n --arg repository "$DEST" --arg base "$BASE" --arg clean "$CLEAN" --arg boundary "$BOUNDARY" --arg zero "$ZERO" \
  '{schema:"atd.pilot-fixture/v1",repository:$repository,baseCommit:$base,
    revisions:{clean:{branch:"clean-change",commit:$clean},boundaryDefect:{branch:"boundary-defect",commit:$boundary},zeroSizeDefect:{branch:"zero-size-defect",commit:$zero}}}'
