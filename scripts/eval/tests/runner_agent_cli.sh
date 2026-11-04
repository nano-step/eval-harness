#!/usr/bin/env bash
# tests/runner_agent_cli.sh — deterministic tests for the omp / claude-code / codex
# runners (runners/{omp,claude-code,codex}.sh + lib/agent_cli.sh).
#
# No real CLI and no provider is ever invoked: PATH shims named omp / claude /
# codex record their argv, stdin, cwd and exit as the runner drives them. Verifies
# the native command shape, exact prompt delivery (stdin, so a leading '-' or '@'
# and multi-line text cannot become options/attachments, nothing is expanded),
# workdir, normalized transcript, failure/timeout propagation with an empty
# transcript, model flags (explicit only), and the 4-subcommand contract through
# lib/runner.sh dispatch.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EVAL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RUNNERS="$EVAL_DIR/runners"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/eval-agent-cli-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1" >&2; }
check() { # <description> <command...>
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$desc"; else fail "$desc"; fi
}

JQ_BIN="$(command -v jq)" || { echo "jq is required for this test" >&2; exit 1; }

# --- fixtures ----------------------------------------------------------------
SHIMS="$WORK/shims"
LOG="$WORK/log"
NOCLI="$WORK/nocli"           # PATH dir with jq only: no agent CLI on PATH
mkdir -p "$SHIMS" "$LOG" "$NOCLI"
ln -s "$JQ_BIN" "$NOCLI/jq"

WD="$WORK/work dir"           # space in the path on purpose
mkdir -p "$WD"
WD_REAL="$(cd "$WD" && pwd -P)"
TR="$WORK/transcript.jsonl"

RESP="$WORK/response.expected"
printf 'He said "hi"\nline2\ttab \\ back\\slash \xc3\xa9 \xe6\x97\xa5\xe6\x9c\xac $(not run) `nor this`\n' > "$RESP"

# The shim: records everything, behaviour chosen by SHIM_MODE.
for name in omp claude codex; do
  cat > "$SHIMS/$name" <<'SHIM'
#!/usr/bin/env bash
d="${SHIM_LOG_DIR:?}"
n="$(basename "$0")"
printf 'x\n' >> "$d/$n.calls"
: > "$d/$n.argv"
for a in "$@"; do printf '%s\n' "$a" >> "$d/$n.argv"; done
pwd -P > "$d/$n.pwd"
cat > "$d/$n.stdin"
case "${SHIM_MODE:-ok}" in
  ok)    cat "${SHIM_RESPONSE_FILE:?}"; echo "diag line" >&2 ;;
  empty) : ;;
  fail)  printf 'partial output\n'; echo "boom" >&2; exit "${SHIM_EXIT:-7}" ;;
  sleep) exec sleep 30 ;;
esac
SHIM
  chmod +x "$SHIMS/$name"
done

# Hostile prompt: leading option-like token, @file attachment syntax, command
# substitution, backticks, quotes, backslash, blank line, trailing spaces.
PROMPT="$(printf -- '-x --help\n@/etc/passwd\n$(touch %s/pwned) `touch %s/pwned2` "dq" '"'"'sq'"'"' \\ end\n\nlast line  ' "$WORK" "$WORK")"
printf '%s' "$PROMPT" > "$WORK/prompt.expected"

# Opencode-style defaults must never leak into the other CLIs.
export EVAL_MODEL="opencode/default-must-not-leak"
export OPENCODE_MODEL="opencode/other-must-not-leak"
unset EVAL_CASE_MODEL EVAL_AB_MODEL_OVERRIDE EVAL_MAX_SECONDS || true
export SHIM_LOG_DIR="$LOG"
export SHIM_RESPONSE_FILE="$RESP"
export PATH="$SHIMS:$PATH"

bin_of() { case "$1" in claude-code) echo claude ;; *) echo "$1" ;; esac; }

expected_argv() { # <runner> <model_or_empty> > file
  local r="$1" m="${2-}"
  case "$r" in
    omp)
      printf '%s\n' -p --mode text --no-session --cwd "$WD_REAL"
      [[ -z "$m" ]] || printf '%s\n' --model "$m" ;;
    claude-code)
      printf '%s\n' -p --output-format text --no-session-persistence
      [[ -z "$m" ]] || printf '%s\n' --model "$m" ;;
    codex)
      printf '%s\n' exec --skip-git-repo-check --sandbox workspace-write -C "$WD_REAL"
      [[ -z "$m" ]] || printf '%s\n' -m "$m"
      printf '%s\n' - ;;
  esac
}

RC=0
# run_spawn <runner> <config_json> <prompt>  — sets RC; resets shim logs.
run_spawn() {
  local r="$1" cfg="$2" prompt="$3"
  rm -f "$LOG"/*
  RC=0
  bash "$RUNNERS/$r.sh" spawn "$WD" "$cfg" "$TR" "$prompt" \
    > "$WORK/runner.stdout" 2> "$WORK/runner.stderr" || RC=$?
}

RUNNER_LIST="omp claude-code codex"

for r in $RUNNER_LIST; do
  b="$(bin_of "$r")"
  echo "== $r: success path =="
  run_spawn "$r" '{}' "$PROMPT"
  [[ "$RC" == "0" ]] && ok "$r: exit 0" || fail "$r: exit $RC (stderr: $(cat "$WORK/runner.stderr"))"
  [[ ! -s "$WORK/runner.stdout" ]] && ok "$r: spawn prints nothing to stdout (run.sh captures it as exit code)" || fail "$r: stdout polluted"
  expected_argv "$r" "" > "$WORK/argv.expected"
  cmp -s "$LOG/$b.argv" "$WORK/argv.expected" && ok "$r: exact native argv (no model, no approval/bypass flags)" \
    || { fail "$r: argv mismatch"; diff "$WORK/argv.expected" "$LOG/$b.argv" >&2 || true; }
  cmp -s "$LOG/$b.stdin" "$WORK/prompt.expected" && ok "$r: prompt delivered byte-exact on stdin" || fail "$r: stdin differs from prompt"
  grep -qF -- '-x --help' "$LOG/$b.argv" && fail "$r: prompt leaked into argv" || ok "$r: prompt never in argv (cannot parse as option)"
  [[ "$(cat "$LOG/$b.pwd")" == "$WD_REAL" ]] && ok "$r: CLI ran in the workdir" || fail "$r: cwd '$(cat "$LOG/$b.pwd")' != '$WD_REAL'"
  [[ ! -e "$WORK/pwned" && ! -e "$WORK/pwned2" ]] && ok "$r: prompt not eval'd or shell-expanded" || fail "$r: prompt was expanded/executed"
  [[ "$(wc -l < "$TR" | tr -d ' ')" == "1" ]] && ok "$r: transcript is exactly one line" || fail "$r: transcript line count"
  "$JQ_BIN" -e '.event == "result" and .type == "assistant" and .runner == "'"$r"'"' "$TR" >/dev/null 2>&1 \
    && ok "$r: transcript is a valid normalized result event" || fail "$r: transcript event shape"
  "$JQ_BIN" -j '.content' "$TR" > "$WORK/content.out"
  cmp -s "$WORK/content.out" "$RESP" && ok "$r: content is the exact CLI stdout" || fail "$r: content differs from CLI stdout"
  "$JQ_BIN" -e '(keys - ["event","type","runner","content","ts"]) == []' "$TR" >/dev/null 2>&1 \
    && ok "$r: no manufactured usage/cost/model fields" || fail "$r: unexpected transcript keys"
  grep -q 'diag line' "$TR.err" && ! grep -q 'diag line' "$TR" && ok "$r: stderr is diagnostics only (.err)" || fail "$r: stderr routing"

  echo "== $r: model flags =="
  run_spawn "$r" '{"model":"my-model/v1"}' "$PROMPT"
  expected_argv "$r" "my-model/v1" > "$WORK/argv.expected"
  [[ "$RC" == "0" ]] && cmp -s "$LOG/$b.argv" "$WORK/argv.expected" && ok "$r: runner_config.model forwarded" || fail "$r: runner_config.model argv"
  "$JQ_BIN" -e '.requested_model == "my-model/v1"' "$TR" >/dev/null 2>&1 && ok "$r: transcript records requested model" || fail "$r: requested_model missing"

  EVAL_CASE_MODEL="case-model-x" run_spawn "$r" '{}' "$PROMPT"
  expected_argv "$r" "case-model-x" > "$WORK/argv.expected"
  [[ "$RC" == "0" ]] && cmp -s "$LOG/$b.argv" "$WORK/argv.expected" && ok "$r: EVAL_CASE_MODEL forwarded" || fail "$r: EVAL_CASE_MODEL argv"

  EVAL_CASE_MODEL="case-model-x" run_spawn "$r" '{"model":"cfg-model"}' "$PROMPT"
  expected_argv "$r" "case-model-x" > "$WORK/argv.expected"
  [[ "$RC" == "0" ]] && cmp -s "$LOG/$b.argv" "$WORK/argv.expected" && ok "$r: EVAL_CASE_MODEL (run.sh case model) wins over runner_config.model" || fail "$r: case-model precedence"

  EVAL_AB_MODEL_OVERRIDE="ab-model-y" EVAL_CASE_MODEL="case-model-x" run_spawn "$r" '{"model":"cfg-model"}' "$PROMPT"
  expected_argv "$r" "ab-model-y" > "$WORK/argv.expected"
  [[ "$RC" == "0" ]] && cmp -s "$LOG/$b.argv" "$WORK/argv.expected" && ok "$r: EVAL_AB_MODEL_OVERRIDE wins over EVAL_CASE_MODEL and runner_config.model" || fail "$r: A/B precedence"

  EVAL_AB_MODEL_OVERRIDE="ab-model-y" run_spawn "$r" '{}' "$PROMPT"
  expected_argv "$r" "ab-model-y" > "$WORK/argv.expected"
  [[ "$RC" == "0" ]] && cmp -s "$LOG/$b.argv" "$WORK/argv.expected" && ok "$r: EVAL_AB_MODEL_OVERRIDE forwarded alone" || fail "$r: A/B alone"

  run_spawn "$r" "" "$PROMPT"
  expected_argv "$r" "" > "$WORK/argv.expected"
  [[ "$RC" == "0" ]] && cmp -s "$LOG/$b.argv" "$WORK/argv.expected" && ok "$r: empty runner_config + EVAL_MODEL/OPENCODE_MODEL set => no model flag" || fail "$r: opencode default leaked"

  echo "== $r: invalid input fails closed =="
  for bad in '{"model":"--dangerously-x"}' '{"model":"has space"}' '{"model":""}' '{"model":5}' '{"modle":"typo"}' '[1]' 'not json'; do
    echo stale > "$TR"
    run_spawn "$r" "$bad" "$PROMPT"
    [[ "$RC" == "2" && ! -s "$TR" && ! -e "$LOG/$b.calls" ]] && ok "$r: rejected runner_config $bad (exit 2, CLI not run, empty transcript)" \
      || fail "$r: runner_config $bad rc=$RC transcript_bytes=$(wc -c < "$TR" | tr -d '[:space:]') called=$([[ -e "$LOG/$b.calls" ]] && echo yes || echo no)"
  done
  EVAL_CASE_MODEL="-rf" run_spawn "$r" '{}' "$PROMPT"
  [[ "$RC" == "2" && ! -e "$LOG/$b.calls" ]] && ok "$r: EVAL_CASE_MODEL with leading dash rejected" || fail "$r: dash EVAL_CASE_MODEL rc=$RC"
  EVAL_AB_MODEL_OVERRIDE="-x" run_spawn "$r" '{}' "$PROMPT"
  [[ "$RC" == "2" && ! -e "$LOG/$b.calls" ]] && ok "$r: EVAL_AB_MODEL_OVERRIDE with leading dash rejected" || fail "$r: dash AB override rc=$RC"
  run_spawn "$r" '{}' ""
  [[ "$RC" == "2" && ! -e "$LOG/$b.calls" ]] && ok "$r: empty prompt rejected" || fail "$r: empty prompt rc=$RC"
  RC=0; bash "$RUNNERS/$r.sh" spawn "$WORK/no-such-dir" '{}' "$TR" "p" >/dev/null 2>&1 || RC=$?
  [[ "$RC" == "2" ]] && ok "$r: missing workdir rejected" || fail "$r: missing workdir rc=$RC"
  EVAL_MAX_SECONDS="abc" run_spawn "$r" '{}' "$PROMPT"
  [[ "$RC" == "2" && ! -e "$LOG/$b.calls" ]] && ok "$r: invalid EVAL_MAX_SECONDS rejected" || fail "$r: EVAL_MAX_SECONDS rc=$RC"

  echo "== $r: failure / timeout propagation =="
  echo stale > "$TR"
  SHIM_MODE=fail SHIM_EXIT=7 run_spawn "$r" '{}' "$PROMPT"
  [[ "$RC" == "7" ]] && ok "$r: non-zero exit propagated (7)" || fail "$r: exit $RC, expected 7"
  [[ ! -s "$TR" ]] && ok "$r: no transcript on failure (stale content cleared)" || fail "$r: transcript left behind"
  grep -q 'boom' "$TR.err" && grep -q 'exited 7' "$TR.err" && ok "$r: failure diagnostics in .err" || fail "$r: .err lacks diagnostics"

  echo stale > "$TR"
  start=$SECONDS
  EVAL_MAX_SECONDS=1 SHIM_MODE=sleep run_spawn "$r" '{}' "$PROMPT"
  elapsed=$((SECONDS - start))
  [[ "$RC" == "124" ]] && ok "$r: timeout propagated (124)" || fail "$r: timeout exit $RC, expected 124"
  [[ ! -s "$TR" ]] && ok "$r: no transcript on timeout" || fail "$r: transcript left after timeout"
  [[ "$elapsed" -lt 20 ]] && ok "$r: timeout enforced via EVAL_MAX_SECONDS (${elapsed}s)" || fail "$r: timeout took ${elapsed}s"

  echo stale > "$TR"
  SHIM_MODE=empty run_spawn "$r" '{}' "$PROMPT"
  [[ "$RC" == "13" && ! -s "$TR" ]] && grep -q 'no stdout' "$WORK/runner.stderr" \
    && ok "$r: exit 0 with zero-byte stdout fails (13) with empty transcript (no false negative-check PASS)" \
    || fail "$r: empty stdout rc=$RC transcript_bytes=$(wc -c < "$TR" | tr -d '[:space:]')"

  echo "== $r: environment =="
  rm -f "$LOG"/*
  RC=0
  PATH="$NOCLI:/usr/bin:/bin" bash "$RUNNERS/$r.sh" spawn "$WD" '{}' "$TR" "$PROMPT" >/dev/null 2>"$WORK/runner.stderr" || RC=$?
  [[ "$RC" == "127" && ! -s "$TR" ]] && grep -q 'not found on PATH' "$WORK/runner.stderr" && ok "$r: missing CLI => 127, empty transcript" || fail "$r: missing CLI rc=$RC"

  mkdir -p "$WORK/relcwd/relbin"
  printf '#!/usr/bin/env bash\ntouch "%s/rel-ran"\n' "$WORK" > "$WORK/relcwd/relbin/$b"
  chmod +x "$WORK/relcwd/relbin/$b"
  RC=0
  ( cd "$WORK/relcwd" && PATH="relbin:$NOCLI:/usr/bin:/bin" bash "$RUNNERS/$r.sh" spawn "$WD" '{}' "$TR" "$PROMPT" >/dev/null 2>&1 ) || RC=$?
  [[ "$RC" == "127" && ! -e "$WORK/rel-ran" ]] && ok "$r: relative-PATH executable refused (cannot be shadowed)" || fail "$r: relative PATH rc=$RC ran=$([[ -e "$WORK/rel-ran" ]] && echo yes || echo no)"

  RC=0
  ( cd "$WORK" && bash "$RUNNERS/$r.sh" spawn "$WD" '{}' "rel-transcript.jsonl" "$PROMPT" >/dev/null 2>&1 ) || RC=$?
  [[ "$RC" == "0" && -s "$WORK/rel-transcript.jsonl" ]] && ok "$r: relative transcript path resolved against caller cwd" || fail "$r: relative transcript rc=$RC"

  echo "== $r: prepare / fingerprint / teardown =="
  RC=0; bash "$RUNNERS/$r.sh" prepare "$WD" '{"model":"m"}' >/dev/null 2>&1 || RC=$?
  [[ "$RC" == "0" ]] && ok "$r: prepare ok with CLI on PATH" || fail "$r: prepare rc=$RC"
  RC=0; bash "$RUNNERS/$r.sh" prepare "$WD" '{"bad":1}' >/dev/null 2>&1 || RC=$?
  [[ "$RC" == "2" ]] && ok "$r: prepare rejects invalid runner_config" || fail "$r: prepare bad config rc=$RC"
  RC=0; PATH="$NOCLI:/usr/bin:/bin" bash "$RUNNERS/$r.sh" prepare "$WD" '{}' >/dev/null 2>&1 || RC=$?
  [[ "$RC" == "127" ]] && ok "$r: prepare fails (127) when CLI missing" || fail "$r: prepare missing CLI rc=$RC"
  fp="$(bash "$RUNNERS/$r.sh" fingerprint "$WD" '{}' 2>/dev/null)" || fp="<error>"
  [[ "$fp" == "unknown" ]] && ok "$r: fingerprint reports unknown (no fabricated identity)" || fail "$r: fingerprint='$fp'"
  RC=0; bash "$RUNNERS/$r.sh" teardown "$WD" >/dev/null 2>&1 || RC=$?
  [[ "$RC" == "0" ]] && ok "$r: teardown no-op" || fail "$r: teardown rc=$RC"
  RC=0; bash "$RUNNERS/$r.sh" bogus >/dev/null 2>&1 || RC=$?
  [[ "$RC" == "2" ]] && ok "$r: unknown subcommand rejected" || fail "$r: bogus subcommand rc=$RC"

  echo "== $r: registry dispatch =="
  rm -f "$LOG"/*
  RC=0
  bash -c 'source "$1/lib/runner.sh"; dispatch_runner spawn "$2" "$3" "$4" "$5" "$6"' _ \
    "$EVAL_DIR" "$r" "$WD" '{}' "$TR" "$PROMPT" >/dev/null 2>&1 || RC=$?
  expected_argv "$r" "" > "$WORK/argv.expected"
  [[ "$RC" == "0" ]] && cmp -s "$LOG/$b.argv" "$WORK/argv.expected" && ok "$r: lib/runner.sh dispatch_runner spawn works" || fail "$r: dispatch rc=$RC"
  bash -c 'source "$1/lib/runner.sh"; list_runners' _ "$EVAL_DIR" | grep -qx "$r" && ok "$r: listed by list_runners" || fail "$r: not listed"
done

echo
echo "== summary =="
echo "  passed: $PASS  failed: $FAIL"
if [[ "$FAIL" -gt 0 ]]; then
  echo "FAIL: runner_agent_cli" >&2
  exit 1
fi
echo "PASS: runner_agent_cli"
