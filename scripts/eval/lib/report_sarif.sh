#!/usr/bin/env bash
# lib/report_sarif.sh — render a results.json into SARIF 2.1.0 (#11).
# Each failed check becomes a result; GitHub Code Scanning and security tooling ingest it.

set -euo pipefail

# Usage: render_sarif <results.json> [tool_version] > results.sarif
render_sarif() {
  local results="$1"
  local version="${2:-0.4.2}"
  jq --arg version "$version" '
    [ .cases[] | select(.passed | not) as $c
      | $c.checks[]? | select(.passed | not)
      | {
          ruleId: (.failed_check_id // "unknown"),
          level: "error",
          message: { text: ((.diff_hint // .failed_check_id) // "check failed") },
          properties: {
            case_id: $c.case_id,
            attribution: ($c.attribution.top // null),
            expected: (.expected | tostring),
            actual: (.actual | tostring)
          }
        }
    ] as $results
    | ($results | map(.ruleId) | unique | map({id: ., shortDescription: {text: .}})) as $rules
    | {
        "$schema": "https://json.schemastore.org/sarif-2.1.0.json",
        version: "2.1.0",
        runs: [
          {
            tool: { driver: { name: "eval-harness", version: $version, rules: $rules } },
            results: $results
          }
        ]
      }
  ' "$results"
}

export -f render_sarif

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-}" in
    render) shift; render_sarif "$@" ;;
    *) echo "usage: report_sarif.sh render <results.json> [version]" >&2; exit 2 ;;
  esac
fi
