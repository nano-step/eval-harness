#!/usr/bin/env bash
# Regression test for #11: SARIF reporter emits valid SARIF 2.1.0 with one result per
# failed check.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/report_sarif.sh"

WORK="$(mktemp -d -t eval-harness-sarif.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/results.json" <<'JSON'
{
  "run_id": "2026-06-17T00-00-00Z-1-1",
  "verdict": "REGRESSION",
  "cases": [
    {"case_id": "case-ok", "passed": true, "checks": [{"kind":"file_exists","passed":true,"failed_check_id":"file_exists:a"}], "attribution": {"top":"UNKNOWN_DRIFT"}},
    {"case_id": "case-bad", "passed": false, "attribution": {"top":"SKILL_CHANGED"},
     "checks": [
       {"kind":"shell","passed":false,"failed_check_id":"shell:echo","expected":"hi","actual":"bye","diff_hint":"output mismatch"},
       {"kind":"file_exists","passed":false,"failed_check_id":"file_exists:out.md","expected":"file present","actual":"missing","diff_hint":"expected file at out.md"}
     ]}
  ]
}
JSON

SARIF="$WORK/out.sarif"
render_sarif "$WORK/results.json" "0.5.0" > "$SARIF"

# Must be valid JSON.
jq -e . "$SARIF" >/dev/null || { echo "FAIL: SARIF is not valid JSON" >&2; cat "$SARIF" >&2; exit 1; }

ver="$(jq -r '.version' "$SARIF")"
[[ "$ver" == "2.1.0" ]] || { echo "FAIL: version=$ver expected 2.1.0" >&2; exit 1; }
tool="$(jq -r '.runs[0].tool.driver.name' "$SARIF")"
[[ "$tool" == "eval-harness" ]] || { echo "FAIL: tool name=$tool" >&2; exit 1; }
toolver="$(jq -r '.runs[0].tool.driver.version' "$SARIF")"
[[ "$toolver" == "0.5.0" ]] || { echo "FAIL: tool version=$toolver expected 0.5.0" >&2; exit 1; }

# Two failed checks -> two results; passing case contributes none.
nres="$(jq '.runs[0].results | length' "$SARIF")"
[[ "$nres" -eq 2 ]] || { echo "FAIL: expected 2 results, got $nres" >&2; cat "$SARIF" >&2; exit 1; }
jq -e '.runs[0] | ([.results[].ruleId] - [.tool.driver.rules[].id] | length) == 0' "$SARIF" >/dev/null \
  || { echo "FAIL: a result ruleId has no driver rule descriptor" >&2; exit 1; }
jq -e '(.runs[0].tool.driver.rules | map(.id)) as $ids | ($ids|length) == ($ids|unique|length)' "$SARIF" >/dev/null \
  || { echo "FAIL: duplicate SARIF rule descriptors" >&2; exit 1; }
jq -e '.runs[0].results[] | select(.ruleId=="shell:echo" and .level=="error")' "$SARIF" >/dev/null \
  || { echo "FAIL: expected a result with ruleId shell:echo level error" >&2; exit 1; }
jq -e '.runs[0].results[] | select(.properties.case_id=="case-bad")' "$SARIF" >/dev/null \
  || { echo "FAIL: result missing case_id property" >&2; exit 1; }

echo "PASS: SARIF reporter — valid 2.1.0, one result per failed check, attribution/case in properties"
exit 0
