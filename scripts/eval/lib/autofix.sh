#!/usr/bin/env bash
set -euo pipefail

propose_fix() {
  local check_result="$1"

  local kind passed
  kind="$(echo "$check_result" | jq -r '.kind // "unknown"')"
  passed="$(echo "$check_result" | jq -r '.passed')"

  if [[ "$passed" == "true" ]]; then
    echo "$check_result" | jq '. + {fix_proposal: null}'
    return 0
  fi

  case "$kind" in
    output_contains)
      local expected
      expected="$(echo "$check_result" | jq -r '.expected')"
      echo "$check_result" | jq --arg literal "$expected" '
        . + {
          fix_proposal: {
            kind: "literal_string_missing",
            confidence: "high",
            instruction: ("Output must contain this exact string: " + $literal),
            patch_snippet: $literal,
            auto_apply: false
          }
        }'
      ;;
    output_not_contains)
      local forbidden
      forbidden="$(echo "$check_result" | jq -r '.expected | sub("^absence of "; "")')"
      echo "$check_result" | jq --arg forbidden "$forbidden" '
        . + {
          fix_proposal: {
            kind: "forbidden_string_present",
            confidence: "high",
            instruction: ("Remove this exact string from output: " + $forbidden),
            patch_snippet: $forbidden,
            auto_apply: false
          }
        }'
      ;;
    jq_path_contains)
      local diff_hint
      diff_hint="$(echo "$check_result" | jq -r '.diff_hint // ""')"
      local missing
      missing="$(echo "$diff_hint" | sed -nE "s/^missing from .*: (.*)$/\1/p")"
      if [[ -n "$missing" ]]; then
        echo "$check_result" | jq --arg missing "$missing" '
          . + {
            fix_proposal: {
              kind: "jq_path_missing_values",
              confidence: "high",
              instruction: ("These required elements are missing from the path: " + $missing),
              patch_snippet: $missing,
              auto_apply: false
            }
          }'
      else
        echo "$check_result" | jq '. + {fix_proposal: null}'
      fi
      ;;
    shell)
      local expected
      expected="$(echo "$check_result" | jq -r '.expected')"
      if [[ "$expected" =~ ^min\  ]]; then
        local min_n="${expected#min }"
        echo "$check_result" | jq --arg n "$min_n" '
          . + {
            fix_proposal: {
              kind: "shell_min_count",
              confidence: "medium",
              instruction: ("Increase the count to at least: " + $n),
              patch_snippet: $n,
              auto_apply: false
            }
          }'
      elif echo "$expected" | grep -qE '^/.*/$|^[^=].*regex' 2>/dev/null; then
        echo "$check_result" | jq --arg re "$expected" '
          . + {
            fix_proposal: {
              kind: "shell_regex_match",
              confidence: "medium",
              instruction: ("Output must match regex: " + $re),
              patch_snippet: $re,
              auto_apply: false
            }
          }'
      else
        echo "$check_result" | jq --arg lit "$expected" '
          . + {
            fix_proposal: {
              kind: "shell_exact_match",
              confidence: "high",
              instruction: ("Output must equal exactly: " + $lit),
              patch_snippet: $lit,
              auto_apply: false
            }
          }'
      fi
      ;;
    file_exists)
      local target
      target="$(echo "$check_result" | jq -r '.failed_check_id | sub("^file_exists:"; "")')"
      echo "$check_result" | jq --arg path "$target" '
        . + {
          fix_proposal: {
            kind: "missing_file",
            confidence: "high",
            instruction: ("Create this file: " + $path),
            patch_snippet: $path,
            auto_apply: false
          }
        }'
      ;;
    llm_judge|*)
      echo "$check_result" | jq '. + {fix_proposal: null}'
      ;;
  esac
}

propose_fixes_for_run() {
  local results_path="$1"
  local out_path="$2"

  jq '
    . as $orig
    | .cases |= map(
        .checks |= map(
          if .passed then . + {fix_proposal: null} else . end
        )
      )
  ' "$results_path" > "$out_path.tmp"

  local enriched
  enriched="$(jq '.cases | map(.case_id)' "$results_path")"
  jq -c '.cases[].checks[]' "$results_path" | while read -r chk; do
    propose_fix "$chk"
  done | jq -s . > "$out_path.checks"

  jq --slurpfile new_checks "$out_path.checks" '
    .cases |= (
      reduce range(0; length) as $i (.;
        .[$i].checks = (
          [$new_checks[0][]
            | select(.failed_check_id as $fcid
                | $fcid as $f
                | .)]
        )
      )
    )
  ' "$out_path.tmp" > "$out_path" 2>/dev/null || cp "$out_path.tmp" "$out_path"

  rm -f "$out_path.tmp" "$out_path.checks"
}

export -f propose_fix propose_fixes_for_run

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-}" in
    check)       shift; propose_fix "$1" ;;
    run)         shift; propose_fixes_for_run "$@" ;;
    *) echo "usage: autofix.sh {check '<json>'|run <results.json> <out.json>}" >&2; exit 2 ;;
  esac
fi
