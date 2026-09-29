#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/../lib/yq-shim.sh"
source "$SCRIPT_DIR/../lib/llm_judge.sh"
source "$SCRIPT_DIR/../lib/autofix.sh"
source "$SCRIPT_DIR/../lib/score.sh"

WORK="$(mktemp -d -t eval-harness-shell.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
printf '{"writes":[]}\n' > "$WORK/nano-brain-store.json"

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


cat > "$WORK/dangerous-python.yaml" <<YAML
kind: shell
cmd: |
  python3 -c 'open("$WORK/python-pwned", "w").close()'
expect_min: 0
YAML
out="$(score_shell "$WORK/dangerous-python.yaml" "$WORK")"
err="$(echo "$out" | jq -r '.error // false')"
[[ "$err" == "true" ]] || { echo "FAIL: python3 interpreter NOT rejected" >&2; echo "$out" >&2; exit 1; }
[[ ! -e "$WORK/python-pwned" ]] || { echo "FAIL: implicit-safe shell grader executed Python code" >&2; exit 1; }

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

printf '{"secret":"CANARY"}\n' > "$WORK/private.json"
mkcheck "$WORK/dangerous-jq-path.yaml" 'cmd: "jq -r .secret ../private.json"' 'expect_exact: CANARY'
out="$(score_shell "$WORK/dangerous-jq-path.yaml" "$WORK")"
[[ "$(echo "$out" | jq -r '.error // false')" == "true" && "$out" != *CANARY* ]] || {
  echo "FAIL: jq path traversal was not rejected without exposing the external file" >&2
  echo "$out" >&2
  exit 1
}
export SAFE_SHELL_SECRET_CANARY=do-not-print
assert_jq_env_rejected() {
  local name="$1" expression="$2" file="$WORK/dangerous-jq-env-$1.yaml"
  cat > "$file" <<YAML
kind: shell
cmd: |
  jq -n '$expression'
expect_exact: "{}"
YAML
  local out
  out="$(score_shell "$file" "$WORK")"
  [[ "$(echo "$out" | jq -r '.error // false')" == "true" && "$out" != *do-not-print* ]] || {
    echo "FAIL: jq environment access $expression was not rejected" >&2
    echo "$out" >&2
    exit 1
  }
}
assert_jq_env_rejected direct 'env'
assert_jq_env_rejected property 'env.PATH'
assert_jq_env_rejected index 'env["SAFE_SHELL_SECRET_CANARY"]'

mkdir "$WORK/path-hijack-workdir"
cat > "$WORK/path-hijack-workdir/jq" <<'SH'
#!/bin/sh
printf 'pwned\n' > "$SAFE_SHELL_PATH_CANARY"
printf 'null\n'
SH
chmod +x "$WORK/path-hijack-workdir/jq"
mkcheck "$WORK/path-hijack.yaml" 'cmd: "jq -n null"' 'expect_exact: "null"'
out="$(PATH=".:$PATH" SAFE_SHELL_PATH_CANARY="$WORK/path-hijacked" score_shell "$WORK/path-hijack.yaml" "$WORK/path-hijack-workdir")"
[[ "$(echo "$out" | jq -r '.error // false')" == "false" && ! -e "$WORK/path-hijacked" ]] || {
  echo "FAIL: default-safe runner resolved jq from the attacker-controlled workdir" >&2
  echo "$out" >&2
  exit 1
}
mkcheck "$WORK/opt-in.yaml" 'cmd: "rm -rf nonexistent_dir"' 'expect_exact: ""' 'unsafe_shell: true'
out="$(score_shell "$WORK/opt-in.yaml" "$WORK")"
err="$(echo "$out" | jq -r '.error // false')"
[[ "$err" == "false" ]] || { echo "FAIL: unsafe_shell:true opt-in still rejected" >&2; echo "$out" >&2; exit 1; }

mkcheck "$WORK/env-override.yaml" \
  'cmd: "rm -rf nonexistent_dir"' \
  'expect_exact: ""'
EVAL_ALLOW_UNSAFE_SHELL=1 out="$(score_shell "$WORK/env-override.yaml" "$WORK")"
err="$(echo "$out" | jq -r '.error // false')"
[[ "$err" == "false" ]] || { echo "FAIL: EVAL_ALLOW_UNSAFE_SHELL=1 still rejected" >&2; echo "$out" >&2; exit 1; }

echo "PASS: constrained shell runner accepts jq/pipelines/printf and rejects interpreters, shell operators, external paths, jq environment access, and workdir executable hijacks; explicit unsafe opt-in remains available"
exit 0
