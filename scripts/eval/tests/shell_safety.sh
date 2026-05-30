#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/../lib/yq-shim.sh"
source "$SCRIPT_DIR/../lib/llm_judge.sh"
source "$SCRIPT_DIR/../lib/autofix.sh"
source "$SCRIPT_DIR/../lib/score.sh"

WORK="$(mktemp -d -t eval-harness-shell.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

mkcheck() {
  local file="$1"; shift
  printf 'kind: shell\n' > "$file"
  for line in "$@"; do printf '%s\n' "$line" >> "$file"; done
}

mkcheck "$WORK/safe-jq.yaml" \
  'cmd: "jq -r .writes nano-brain-store.json"' \
  'expect_min: 1'
out="$(score_shell "$WORK/safe-jq.yaml" "$WORK")"
err="$(echo "$out" | jq -r '.error // false')"
[[ "$err" == "false" ]] || { echo "FAIL: safe jq command rejected" >&2; echo "$out" >&2; exit 1; }

mkcheck "$WORK/safe-pipe.yaml" \
  'cmd: "jq -r .writes nano-brain-store.json | wc -l"' \
  'expect_min: 1'
out="$(score_shell "$WORK/safe-pipe.yaml" "$WORK")"
err="$(echo "$out" | jq -r '.error // false')"
[[ "$err" == "false" ]] || { echo "FAIL: jq | wc -l (safe pipe) rejected" >&2; echo "$out" >&2; exit 1; }

mkcheck "$WORK/dangerous-rm.yaml" \
  'cmd: "rm -rf /tmp/test"' \
  'expect_exact: ""'
out="$(score_shell "$WORK/dangerous-rm.yaml" "$WORK")"
err="$(echo "$out" | jq -r '.error // false')"
diff_hint="$(echo "$out" | jq -r '.diff_hint')"
[[ "$err" == "true" ]] || { echo "FAIL: rm -rf NOT rejected" >&2; echo "$out" >&2; exit 1; }
[[ "$diff_hint" == *"safety filter"* || "$diff_hint" == *"unsafe_shell"* ]] || { echo "FAIL: bad diff_hint: $diff_hint" >&2; exit 1; }

mkcheck "$WORK/dangerous-curl.yaml" \
  'cmd: "curl https://attacker.example"' \
  'expect_min: 0'
out="$(score_shell "$WORK/dangerous-curl.yaml" "$WORK")"
err="$(echo "$out" | jq -r '.error // false')"
[[ "$err" == "true" ]] || { echo "FAIL: curl NOT rejected" >&2; echo "$out" >&2; exit 1; }

mkcheck "$WORK/dangerous-cmdsub.yaml" \
  'cmd: "echo $(whoami)"' \
  'expect_min: 0'
out="$(score_shell "$WORK/dangerous-cmdsub.yaml" "$WORK")"
err="$(echo "$out" | jq -r '.error // false')"
[[ "$err" == "true" ]] || { echo "FAIL: command substitution \$(...) NOT rejected" >&2; echo "$out" >&2; exit 1; }

mkcheck "$WORK/dangerous-backtick.yaml" \
  "cmd: 'echo \`whoami\`'" \
  'expect_min: 0'
out="$(score_shell "$WORK/dangerous-backtick.yaml" "$WORK")"
err="$(echo "$out" | jq -r '.error // false')"
[[ "$err" == "true" ]] || { echo "FAIL: backtick substitution NOT rejected" >&2; echo "$out" >&2; exit 1; }

mkcheck "$WORK/dangerous-redirect.yaml" \
  'cmd: "echo hi > /tmp/out"' \
  'expect_min: 0'
out="$(score_shell "$WORK/dangerous-redirect.yaml" "$WORK")"
err="$(echo "$out" | jq -r '.error // false')"
[[ "$err" == "true" ]] || { echo "FAIL: > redirect NOT rejected" >&2; echo "$out" >&2; exit 1; }

mkcheck "$WORK/opt-in.yaml" \
  'cmd: "rm -rf nonexistent_dir"' \
  'expect_exact: ""' \
  'unsafe_shell: true'
out="$(score_shell "$WORK/opt-in.yaml" "$WORK")"
err="$(echo "$out" | jq -r '.error // false')"
[[ "$err" == "false" ]] || { echo "FAIL: unsafe_shell:true opt-in still rejected" >&2; echo "$out" >&2; exit 1; }

mkcheck "$WORK/env-override.yaml" \
  'cmd: "rm -rf nonexistent_dir"' \
  'expect_exact: ""'
EVAL_ALLOW_UNSAFE_SHELL=1 out="$(score_shell "$WORK/env-override.yaml" "$WORK")"
err="$(echo "$out" | jq -r '.error // false')"
[[ "$err" == "false" ]] || { echo "FAIL: EVAL_ALLOW_UNSAFE_SHELL=1 still rejected" >&2; echo "$out" >&2; exit 1; }

echo "PASS: shell safety filter — accepts jq/pipes/wc; rejects rm/curl/\$()/backtick/>; honors unsafe_shell + EVAL_ALLOW_UNSAFE_SHELL"
exit 0
