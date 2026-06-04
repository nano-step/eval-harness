#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d -t eval-harness-yq.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/case.yaml" <<'YAML'
model: anthropic/claude-from-case
budget_usd: 5.00
unsafe_shell: true # inline comment should not change the boolean
skills_loaded: [omo-session-distiller, pr-code-reviewer]
setup:
  fixtures:
    "session-input.json": fixtures/session-input.json
commented_setup: # inline comment before nested mapping
  enabled: true
optional_items:
  - # comment-only empty item
  - named
prompt: |
  Read the fixture.
  Write a result.
checks:
  - kind: file_exists
    path: result.json
  - kind: jq_path_contains
    file: result.json
    path: "[.writes[].tags[]] | unique"
    contains: ["decision", "architecture"]
  - shell: # inline comment before nested mapping
      cmd: "echo nested"
      expect_exact: nested
llm_judge:
  model: anthropic/claude-opus-4-7
YAML

YQ="$SCRIPT_DIR/../lib/_yq.py"
export EVAL_YQ_FORCE_STDLIB=1

[[ "$(python3 "$YQ" -r '.model' "$WORK/case.yaml")" == "anthropic/claude-from-case" ]] || {
  echo "FAIL: scalar lookup failed" >&2
  exit 1
}

skills="$(python3 "$YQ" -r '.skills_loaded[]' "$WORK/case.yaml" | paste -sd ' ' -)"
[[ "$skills" == "omo-session-distiller pr-code-reviewer" ]] || {
  echo "FAIL: inline list iteration failed: $skills" >&2
  exit 1
}

[[ "$(python3 "$YQ" -r '.prompt' "$WORK/case.yaml")" == $'Read the fixture.\nWrite a result.' ]] || {
  echo "FAIL: block scalar lookup failed" >&2
  exit 1
}

[[ "$(python3 "$YQ" -r '.unsafe_shell // false' "$WORK/case.yaml")" == "true" ]] || {
  echo "FAIL: inline comment changed scalar value" >&2
  exit 1
}

[[ "$(python3 "$YQ" -r '.commented_setup.enabled // false' "$WORK/case.yaml")" == "true" ]] || {
  echo "FAIL: inline comment before nested mapping failed" >&2
  exit 1
}

[[ "$(python3 "$YQ" -o=json '.optional_items' "$WORK/case.yaml" | jq -c '.')" == '[null,"named"]' ]] || {
  echo "FAIL: comment-only list item did not parse as empty item" >&2
  exit 1
}

[[ "$(python3 "$YQ" -r '.checks | length' "$WORK/case.yaml")" == "3" ]] || {
  echo "FAIL: list length failed" >&2
  exit 1
}

python3 "$YQ" -o=json '.checks[1]' "$WORK/case.yaml" > "$WORK/check.json"
[[ "$(python3 "$YQ" -r '.kind' "$WORK/check.json")" == "jq_path_contains" ]] || {
  echo "FAIL: indexed object emit/parse failed" >&2
  exit 1
}

[[ "$(python3 "$YQ" -o=json '.contains' "$WORK/check.json" | jq -r 'join(",")')" == "decision,architecture" ]] || {
  echo "FAIL: nested inline array failed" >&2
  exit 1
}

[[ "$(python3 "$YQ" -r '.checks[2].shell.cmd' "$WORK/case.yaml")" == "echo nested" ]] || {
  echo "FAIL: nested mapping list item failed" >&2
  exit 1
}

[[ "$(python3 "$YQ" -r '.llm_judge.model // ""' "$WORK/case.yaml")" == "anthropic/claude-opus-4-7" ]] || {
  echo "FAIL: nested default expression failed" >&2
  exit 1
}

echo "PASS: yq shim parses eval-harness YAML subset with python stdlib"
