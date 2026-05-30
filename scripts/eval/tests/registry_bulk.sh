#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REG="$SCRIPT_DIR/../lib/registry.sh"

WORK="$(mktemp -d -t eval-harness-bulk.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

export EVAL_HARNESS_REGISTRY="$WORK/registry.yaml"

WORKSPACE="$WORK/workspace"
mkdir -p "$WORKSPACE"

mkrepo() {
  local name="$1"; shift
  local dir="$WORKSPACE/$name"
  mkdir -p "$dir/.git"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --skills)
        mkdir -p "$dir/.opencode/skills/example-skill"
        echo "demo" > "$dir/.opencode/skills/example-skill/SKILL.md"
        ;;
      --cases)
        mkdir -p "$dir/.opencode/skills/example-skill/evals/cases"
        echo "id: c1" > "$dir/.opencode/skills/example-skill/evals/cases/c1.yaml"
        ;;
    esac
    shift
  done
}

mkrepo plain-repo
mkrepo skill-only --skills
mkrepo skill-and-cases --skills --cases
mkrepo another-skill-repo --skills
mkrepo unrelated

discovered_all="$(bash "$REG" discover "$WORKSPACE" all 3 | tr '\n' ',' | sed 's/,$//')"
[[ "$discovered_all" == "another-skill-repo,plain-repo,skill-and-cases,skill-only,unrelated" ]] \
  || { echo "FAIL: filter=all got '$discovered_all'" >&2; exit 1; }

discovered_skills="$(bash "$REG" discover "$WORKSPACE" skills 3 | tr '\n' ',' | sed 's/,$//')"
[[ "$discovered_skills" == "another-skill-repo,skill-and-cases,skill-only" ]] \
  || { echo "FAIL: filter=skills got '$discovered_skills'" >&2; exit 1; }

discovered_cases="$(bash "$REG" discover "$WORKSPACE" cases 3 | tr '\n' ',' | sed 's/,$//')"
[[ "$discovered_cases" == "skill-and-cases" ]] \
  || { echo "FAIL: filter=cases got '$discovered_cases'" >&2; exit 1; }

[[ ! -f "$EVAL_HARNESS_REGISTRY" ]] \
  || { echo "FAIL: discover should NOT create registry file, but $EVAL_HARNESS_REGISTRY exists" >&2; exit 1; }

out_dry="$(bash "$REG" enable-workspace --root="$WORKSPACE" --filter=skills --dry-run 2>&1)"
echo "$out_dry" | grep -q "discovered 3 repo" \
  || { echo "FAIL: dry-run summary missing repo count" >&2; echo "$out_dry" >&2; exit 1; }
echo "$out_dry" | grep -q "not writing" \
  || { echo "FAIL: dry-run did not announce no-write" >&2; echo "$out_dry" >&2; exit 1; }
[[ ! -f "$EVAL_HARNESS_REGISTRY" ]] \
  || { echo "FAIL: dry-run created registry file" >&2; exit 1; }

bash "$REG" enable manual-repo >/dev/null
manual_count_before="$(bash "$REG" list | wc -l | tr -d ' ')"
[[ "$manual_count_before" == "1" ]] \
  || { echo "FAIL: registry should have 1 entry after manual enable, has $manual_count_before" >&2; exit 1; }

bash "$REG" enable-workspace --root="$WORKSPACE" --filter=skills >/dev/null 2>&1
all_enabled="$(bash "$REG" list | sort | tr '\n' ',' | sed 's/,$//')"
[[ "$all_enabled" == "another-skill-repo,manual-repo,skill-and-cases,skill-only" ]] \
  || { echo "FAIL: after bulk enable, list='$all_enabled' (expected manual-repo + 3 skill repos)" >&2; exit 1; }

bash "$REG" enable-workspace --root="$WORKSPACE" --filter=skills >/dev/null 2>&1
all_enabled_2="$(bash "$REG" list | sort | tr '\n' ',' | sed 's/,$//')"
[[ "$all_enabled" == "$all_enabled_2" ]] \
  || { echo "FAIL: re-running bulk-enable changed registry; before='$all_enabled' after='$all_enabled_2'" >&2; exit 1; }

if bash "$REG" enable-workspace --root="$WORKSPACE" --filter=bogus 2>/dev/null; then
  echo "FAIL: invalid --filter should exit non-zero" >&2; exit 1
fi

if bash "$REG" enable-workspace --root=/this/does/not/exist --filter=all 2>/dev/null; then
  echo "FAIL: nonexistent --root should exit non-zero" >&2; exit 1
fi

if bash "$REG" enable-workspace --root="$WORKSPACE" --max-depth=foo 2>/dev/null; then
  echo "FAIL: bad --max-depth should exit non-zero" >&2; exit 1
fi

empty_root="$WORK/empty-workspace"
mkdir -p "$empty_root"
bash "$REG" enable-workspace --root="$empty_root" --filter=skills > "$WORK/empty.log" 2>&1
grep -q "no repos matched" "$WORK/empty.log" \
  || { echo "FAIL: empty workspace should print 'no repos matched'" >&2; cat "$WORK/empty.log" >&2; exit 1; }

echo "PASS: enable-workspace — discover (all/skills/cases filters), dry-run, single-write merge, idempotent re-run, preserves manual entries, rejects bad input"
exit 0
