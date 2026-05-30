#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

WORK="$(mktemp -d -t eval-harness-fix.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/results.json" <<'JSON'
{
  "schema_version": 2,
  "run_id": "test-run",
  "trigger": "manual",
  "verdict": "FAIL",
  "summary": {"total": 1, "pass": 0, "fail": 1, "regression_count": 0, "total_cost_usd": 0},
  "regressions": [],
  "cases": [{
    "case_id": "demo",
    "passed": false,
    "baseline_passed": null,
    "checks": [{
      "kind": "output_contains",
      "passed": false,
      "failed_check_id": "output_contains:HELLO",
      "expected": "HELLO",
      "actual": "absent",
      "diff_hint": "transcript does not contain: HELLO",
      "fix_proposal": {
        "kind": "literal_string_missing",
        "confidence": "high",
        "instruction": "Output must contain this exact string: HELLO",
        "patch_snippet": "HELLO",
        "auto_apply": false
      }
    }],
    "env_delta": {"keys_changed": [], "details": {}},
    "attribution": {"top": "UNKNOWN_DRIFT", "also_observed": [], "evidence": {}},
    "env_manifest": {},
    "cost": {"usd": 0},
    "rerun": "bash scripts/eval/run.sh --case=demo --skill=foo --debug"
  }]
}
JSON

source "$SCRIPT_DIR/../lib/yq-shim.sh"
source "$SCRIPT_DIR/../lib/attribute.sh"
source "$SCRIPT_DIR/../lib/manifest.sh"
source "$SCRIPT_DIR/../lib/pricing.sh"
source "$SCRIPT_DIR/../lib/diff.sh"

render_diff_md "$WORK/results.json" "$WORK/diff.md"

grep -q "fix_proposal" "$WORK/diff.md" || {
  echo "FAIL: fix_proposal not rendered in diff.md" >&2
  cat "$WORK/diff.md" >&2
  exit 1
}
grep -q "literal_string_missing" "$WORK/diff.md" || {
  echo "FAIL: kind not rendered" >&2
  exit 1
}
grep -q "patch snippet" "$WORK/diff.md" || {
  echo "FAIL: patch_snippet not rendered" >&2
  exit 1
}
grep -q "Output must contain this exact string: HELLO" "$WORK/diff.md" || {
  echo "FAIL: instruction not rendered" >&2
  exit 1
}

cat > "$WORK/results-pass.json" <<'JSON'
{
  "schema_version": 2,
  "run_id": "test-run-pass",
  "trigger": "manual",
  "verdict": "PASS",
  "summary": {"total": 1, "pass": 1, "fail": 0, "regression_count": 0, "total_cost_usd": 0},
  "regressions": [],
  "cases": [{
    "case_id": "demo-pass",
    "passed": true,
    "baseline_passed": null,
    "checks": [{"kind": "file_exists", "passed": true, "failed_check_id": "x", "expected": "y", "actual": "y", "diff_hint": "", "fix_proposal": null}],
    "env_delta": {"keys_changed": [], "details": {}},
    "attribution": {"top": "UNKNOWN_DRIFT", "also_observed": [], "evidence": {}},
    "env_manifest": {},
    "cost": {"usd": 0},
    "rerun": ""
  }]
}
JSON
render_diff_md "$WORK/results-pass.json" "$WORK/diff-pass.md"
grep -q "fix_proposal" "$WORK/diff-pass.md" && {
  echo "FAIL: fix_proposal should not appear when null" >&2
  cat "$WORK/diff-pass.md" >&2
  exit 1
} || true

echo "PASS: fix_proposal renders in diff.md when non-null; absent when null"
exit 0
