#!/usr/bin/env bash
# lib/diff.sh — compute 6-field FAIL diff between a fresh run and baseline.
# Settled Decision #4: 6-field schema = failed_check_id, expected, actual, diff_hint,
# transcript_span, env_delta. Settled #5: 4-class attribution from env_delta.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/attribute.sh"
source "$SCRIPT_DIR/manifest.sh"

# Usage: build_case_result <case_id> <run_dir> <baseline_path>
# Emits a single case-result JSON (top-level item for results.json).
build_case_result() {
  local case_id="$1"
  local run_dir="$2"
  local baseline="$3"

  local checks_file="$run_dir/checks.json"
  local manifest_file="$run_dir/env-manifest.json"
  local transcript="$run_dir/transcript.jsonl"

  local passed
  passed="$(jq -r '.passed' "$checks_file" 2>/dev/null || echo false)"

  local baseline_passed=null
  local env_delta='{"keys_changed": ["__no_baseline__"], "details": {}}'
  if [[ -f "$baseline" ]]; then
    baseline_passed="$(jq -r '.passed' "$baseline" 2>/dev/null || echo null)"
    local baseline_manifest_tmp; baseline_manifest_tmp="$(mktemp)"
    jq '.env_manifest // {}' "$baseline" > "$baseline_manifest_tmp"
    env_delta="$(diff_manifests "$baseline_manifest_tmp" "$manifest_file")"
    rm -f "$baseline_manifest_tmp"
  fi

  local attribution='{"top": "UNKNOWN_DRIFT", "also_observed": [], "evidence": {}}'
  if [[ "$passed" == "false" ]]; then
    attribution="$(attribute "$env_delta")"
  fi

  local rerun_cmd="bash scripts/eval/run.sh --case=$case_id --skill=\${SKILL_UNDER_TEST} --debug --pin-env=baseline"

  jq -n \
    --arg case_id "$case_id" \
    --argjson passed "$passed" \
    --argjson baseline_passed "$baseline_passed" \
    --slurpfile checks "$checks_file" \
    --argjson env_delta "$env_delta" \
    --argjson attribution "$attribution" \
    --slurpfile manifest "$manifest_file" \
    --arg rerun "$rerun_cmd" \
    '{
      case_id: $case_id,
      passed: $passed,
      baseline_passed: $baseline_passed,
      checks: ($checks[0].checks // []),
      env_delta: $env_delta,
      attribution: $attribution,
      env_manifest: ($manifest[0] // {}),
      rerun: $rerun
    }'
}

# Usage: build_run_summary <results_array_json> <run_id> <trigger>
# Aggregates per-case results into the top-level results.json.
build_run_summary() {
  local results_json="$1"
  local run_id="$2"
  local trigger="$3"

  local total; total="$(echo "$results_json" | jq 'length')"
  local pass; pass="$(echo "$results_json" | jq '[.[] | select(.passed)] | length')"
  local fail; fail="$(echo "$results_json" | jq '[.[] | select(.passed | not)] | length')"
  local regressions; regressions="$(echo "$results_json" | jq '[.[] | select(.baseline_passed == true and .passed == false) | .case_id]')"
  local regression_count; regression_count="$(echo "$regressions" | jq 'length')"

  local verdict="PASS"
  if [[ "$regression_count" -gt 0 ]]; then
    verdict="REGRESSION"
  elif [[ "$fail" -gt 0 ]]; then
    verdict="FAIL"
  fi

  jq -n \
    --arg run_id "$run_id" \
    --arg trigger "$trigger" \
    --arg verdict "$verdict" \
    --argjson total "$total" \
    --argjson pass "$pass" \
    --argjson fail "$fail" \
    --argjson regressions "$regressions" \
    --argjson cases "$results_json" \
    '{
      schema_version: 2,
      run_id: $run_id,
      trigger: $trigger,
      verdict: $verdict,
      summary: {
        total: $total,
        pass: $pass,
        fail: $fail,
        regression_count: ($regressions | length)
      },
      regressions: $regressions,
      cases: $cases
    }'
}

# Usage: render_diff_md <results_json_path> <out_md_path>
# Writes a human-readable markdown summary per Settled Decision #15.
render_diff_md() {
  local results="$1"
  local out="$2"

  local verdict; verdict="$(jq -r '.verdict' "$results")"
  local run_id; run_id="$(jq -r '.run_id' "$results")"
  local trigger; trigger="$(jq -r '.trigger' "$results")"

  {
    echo "# eval-harness run $run_id"
    echo
    echo "- trigger: \`$trigger\`"
    echo "- verdict: **$verdict**"
    echo
    local regressions; regressions="$(jq -r '.regressions | length' "$results")"
    if [[ "$regressions" -gt 0 ]]; then
      echo "## REGRESSION ($regressions)"
      echo
      jq -r '.cases[] | select(.baseline_passed == true and .passed == false) |
        "### " + .case_id + "\n" +
        "- attribution: **" + .attribution.top + "**" +
          (if (.attribution.also_observed | length) > 0
           then " (also: " + (.attribution.also_observed | join(", ")) + ")"
           else "" end) + "\n" +
        "- env_delta keys: " + (.env_delta.keys_changed | join(", ")) + "\n" +
        "- failed checks: " + ([.checks[] | select(.passed | not) | .failed_check_id] | join("; ")) + "\n" +
        "\n#### Rerun in isolation\n" +
        "```\n" + .rerun + "\n```\n"
      ' "$results"
    fi

    local fails; fails="$(jq -r '[.cases[] | select(.passed == false)] | length' "$results")"
    if [[ "$fails" -gt 0 ]]; then
      echo "## FAILED CHECKS (full detail)"
      echo
      jq -r '.cases[] | select(.passed == false) |
        "### " + .case_id + "\n" +
        ([.checks[] | select(.passed | not) |
          "- **" + .failed_check_id + "**\n" +
          "  - expected: `" + (.expected | tostring) + "`\n" +
          "  - actual:   `" + (.actual | tostring) + "`\n" +
          "  - hint:     " + (.diff_hint // "")
        ] | join("\n")) + "\n"
      ' "$results"
    fi

    local stable; stable="$(jq -r '[.cases[] | select(.passed == true)] | length' "$results")"
    if [[ "$stable" -gt 0 ]]; then
      echo "## STABLE"
      echo
      jq -r '.cases[] | select(.passed == true) | "- " + .case_id + ": PASS"' "$results"
    fi
  } > "$out"
}

export -f build_case_result build_run_summary render_diff_md

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-}" in
    case)    shift; build_case_result "$@" ;;
    summary) shift; build_run_summary "$@" ;;
    md)      shift; render_diff_md "$@" ;;
    *) echo "usage: diff.sh {case <id> <run_dir> <baseline> | summary <results_json> <run_id> <trigger> | md <results.json> <out.md>}" >&2; exit 2 ;;
  esac
fi
