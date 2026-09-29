#!/usr/bin/env bash
# Regression test for #11: JUnit reporter emits well-formed XML with a testcase per case
# and a <failure> for failed cases.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/report_junit.sh"

WORK="$(mktemp -d -t eval-harness-junit.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/results.json" <<'JSON'
{
  "run_id": "2026-06-17T00-00-00Z-1-1",
  "verdict": "REGRESSION",
  "summary": {"total": 2, "pass": 1, "fail": 1},
  "cases": [
    {"case_id": "case-ok", "passed": true, "checks": [{"kind":"file_exists","passed":true,"failed_check_id":"file_exists:a"}], "attribution": {"top": "UNKNOWN_DRIFT"}},
    {"case_id": "case-bad", "passed": false, "attribution": {"top": "SKILL_CHANGED"},
     "checks": [{"kind":"shell","passed":false,"failed_check_id":"shell:echo","expected":"hi","actual":"bye","diff_hint":"output mismatch <&\"'>"}]}
  ]
}
JSON

XML="$WORK/junit.xml"
render_junit "$WORK/results.json" > "$XML"

# Well-formedness: prefer xmllint, else fall back to a python xml.dom parse.
if command -v xmllint >/dev/null 2>&1; then
  xmllint --noout "$XML" || { echo "FAIL: xmllint rejected the JUnit XML" >&2; cat "$XML" >&2; exit 1; }
else
  python3 - "$XML" <<'PY' || { echo "FAIL: JUnit XML is not well-formed" >&2; exit 1; }
import sys, xml.dom.minidom as m
m.parse(sys.argv[1])
PY
fi

grep -q 'tests="2"' "$XML" || { echo "FAIL: testsuite tests count missing/wrong" >&2; cat "$XML" >&2; exit 1; }
grep -q 'failures="1"' "$XML" || { echo "FAIL: testsuite failures count missing/wrong" >&2; cat "$XML" >&2; exit 1; }
grep -q 'name="case-ok"' "$XML" || { echo "FAIL: passing testcase missing" >&2; exit 1; }
grep -q 'name="case-bad"' "$XML" || { echo "FAIL: failing testcase missing" >&2; exit 1; }
grep -q '<failure ' "$XML" || { echo "FAIL: <failure> element missing for failed case" >&2; exit 1; }
grep -q 'type="SKILL_CHANGED"' "$XML" || { echo "FAIL: failure type (attribution) missing" >&2; exit 1; }
# Raw special chars must be escaped in the message attribute (no bare < or & or ").
grep -q 'message="output mismatch &lt;&amp;&quot;' "$XML" || { echo "FAIL: special chars not XML-escaped in message" >&2; cat "$XML" >&2; exit 1; }

echo "PASS: JUnit reporter — well-formed XML, per-case testcases, escaped failure with attribution type"
exit 0
