#!/usr/bin/env bash
# tests/pre_push_branch_filter.sh — unit tests for pre_push_should_fire helper.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d -t eval-harness-ppbf.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

# Initialise a minimal git repo so resolve_project_config can walk the tree.
mkdir -p "$WORK/proj/.opencode"
cd "$WORK/proj"
git init -q

# Source libs (same order as project_config.sh test)
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/yq-shim.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/skills_root.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/config.sh"

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Helper: write a config and call pre_push_should_fire.
# Usage: should_fire <branch>   -> returns 0/1 from the function
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Test 1: Neither include nor exclude set -> always fire
# ---------------------------------------------------------------------------
cat > "$WORK/proj/.opencode/eval-harness.yaml" <<YAML
model: test
YAML

pre_push_should_fire "main"      && pass "no-filter: main fires"    || fail "no-filter: main should fire"
pre_push_should_fire "wip/foo"   && pass "no-filter: wip/foo fires" || fail "no-filter: wip/foo should fire"
pre_push_should_fire "feature/x" && pass "no-filter: feature/x fires" || fail "no-filter: feature/x should fire"

# ---------------------------------------------------------------------------
# Test 2: include list set — only matching branches fire
# ---------------------------------------------------------------------------
cat > "$WORK/proj/.opencode/eval-harness.yaml" <<YAML
pre_push:
  branches:
    include:
      - main
      - "release/*"
      - "hotfix/*"
YAML

pre_push_should_fire "main"       && pass "include: main fires"         || fail "include: main should fire"
pre_push_should_fire "release/1.0" && pass "include: release/1.0 fires" || fail "include: release/1.0 should fire"
pre_push_should_fire "hotfix/abc" && pass "include: hotfix/abc fires"   || fail "include: hotfix/abc should fire"

pre_push_should_fire "wip/foo"   && fail "include: wip/foo should be skipped"   || pass "include: wip/foo skipped"
pre_push_should_fire "feature/x" && fail "include: feature/x should be skipped" || pass "include: feature/x skipped"
pre_push_should_fire "draft/bar" && fail "include: draft/bar should be skipped"  || pass "include: draft/bar skipped"

# ---------------------------------------------------------------------------
# Test 3: exclude list set — matching branches are skipped, others fire
# ---------------------------------------------------------------------------
cat > "$WORK/proj/.opencode/eval-harness.yaml" <<YAML
pre_push:
  branches:
    exclude:
      - "wip/*"
      - "draft/*"
      - "experiment/*"
YAML

pre_push_should_fire "main"         && pass "exclude: main fires"       || fail "exclude: main should fire"
pre_push_should_fire "release/2.0"  && pass "exclude: release/2.0 fires" || fail "exclude: release/2.0 should fire"
pre_push_should_fire "feature/cool" && pass "exclude: feature/cool fires" || fail "exclude: feature/cool should fire"

pre_push_should_fire "wip/foo"       && fail "exclude: wip/foo should be skipped"       || pass "exclude: wip/foo skipped"
pre_push_should_fire "draft/pr"      && fail "exclude: draft/pr should be skipped"      || pass "exclude: draft/pr skipped"
pre_push_should_fire "experiment/x"  && fail "exclude: experiment/x should be skipped"  || pass "exclude: experiment/x skipped"

# ---------------------------------------------------------------------------
# Test 4: Both include and exclude set — include wins (branch must match include)
# ---------------------------------------------------------------------------
cat > "$WORK/proj/.opencode/eval-harness.yaml" <<YAML
pre_push:
  branches:
    include:
      - main
      - "release/*"
    exclude:
      - "wip/*"
      - "draft/*"
YAML

pre_push_should_fire "main"        && pass "both: main fires"         || fail "both: main should fire"
pre_push_should_fire "release/3.0" && pass "both: release/3.0 fires"  || fail "both: release/3.0 should fire"

pre_push_should_fire "wip/foo"  && fail "both: wip/foo should be skipped (not in include)"  || pass "both: wip/foo skipped"
pre_push_should_fire "draft/pr" && fail "both: draft/pr should be skipped (not in include)" || pass "both: draft/pr skipped"
pre_push_should_fire "feature/x" && fail "both: feature/x should be skipped (not in include)" || pass "both: feature/x skipped"

# ---------------------------------------------------------------------------
# Test 5: No config file at all -> fire (resolve_project_config returns empty)
# ---------------------------------------------------------------------------
rm -f "$WORK/proj/.opencode/eval-harness.yaml"
unset EVAL_HARNESS_CONFIG 2>/dev/null || true

pre_push_should_fire "wip/anything" && pass "no-config: wip/anything fires" || fail "no-config: should fire when no config"

echo ""
echo "PASS: all pre_push_branch_filter tests passed"
exit 0
