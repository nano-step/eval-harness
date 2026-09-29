#!/usr/bin/env bash
# lib/report_junit.sh — render a results.json into JUnit XML (#11).
# Every case is a <testcase>; a failed case carries a <failure> whose message is the
# first failed check's diff_hint and whose type is the attribution class. CI systems
# (GitHub Actions, GitLab, Jenkins) consume this directly.

set -euo pipefail

# Usage: render_junit <results.json> > junit.xml
render_junit() {
  local results="$1"
  jq -r '
    def esc: tostring | @html;
    (.run_id // "eval-harness") as $rid
    | .cases as $cases
    | ($cases | length) as $total
    | ([$cases[] | select(.passed | not)] | length) as $fails
    | (([$cases[] | (.duration_ms // 0)] | add // 0) / 1000) as $suite_time
    | "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
      "<testsuites>",
      "  <testsuite name=\"\($rid | esc)\" tests=\"\($total)\" failures=\"\($fails)\" time=\"\($suite_time)\">",
      ( $cases[]
        | ((.duration_ms // 0) / 1000) as $t
        | if .passed then
            "    <testcase name=\"\(.case_id | esc)\" time=\"\($t)\"></testcase>"
          else
            ( [.checks[]? | select(.passed | not)] ) as $fc
            | ( ($fc[0].diff_hint // $fc[0].failed_check_id) // "check failed" ) as $msg
            | ( .attribution.top // "UNKNOWN" ) as $type
            | ( $fc | map("\(.failed_check_id): expected=\(.expected | tostring) actual=\(.actual | tostring) hint=\(.diff_hint // "")") | join("\n") | gsub("]]>"; "]]]]><![CDATA[>") ) as $detail
            | "    <testcase name=\"\(.case_id | esc)\" time=\"\($t)\">",
              "      <failure message=\"\($msg | esc)\" type=\"\($type | esc)\"><![CDATA[\($detail)]]></failure>",
              "    </testcase>"
          end
      ),
      "  </testsuite>",
      "</testsuites>"
  ' "$results"
}

export -f render_junit

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-}" in
    render) shift; render_junit "$@" ;;
    *) echo "usage: report_junit.sh render <results.json>" >&2; exit 2 ;;
  esac
fi
