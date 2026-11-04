#!/usr/bin/env bash
# runner_custom: end-to-end behavior of run.sh for adapter-file runners that are not opencode,
# langgraph-node or atd-sandbox (custom adapters resolved through EVAL_RUNNERS_DIR, and the
# built-in agent names omp / claude-code / codex).
#
# Every case drives the REAL run.sh against disposable fake adapters and fake agent binaries.
# Covers: custom runner names, CLI/EVAL_RUNNER selection for cases that name no runner, missing
# adapters, path-traversal names, binary-only preflight for built-in names, mixed runners without
# per-case env leakage, prepare/spawn/fingerprint/teardown lifecycle (primary + stability samples),
# failure/timeout exit semantics and non-opencode provenance.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EVAL_BIN="$SCRIPT_DIR/../run.sh"
LIB="$SCRIPT_DIR/../lib"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

for tool in jq python3; do
  command -v "$tool" >/dev/null 2>&1 || { echo "SKIP: $tool not installed"; exit 0; }
done

WORK="$(mktemp -d -t eval-harness-runner-custom.XXXXXX)"
COMPLETED=0
# Fail closed: an exit 0 is only believable when the script reached its final line, so a parse error,
# an aborted section or a truncated file can never be reported as success.
trap 'rc=$?; rm -rf "$WORK"; if [[ "$rc" == "0" && "$COMPLETED" != "1" ]]; then echo "FAIL: runner_custom.sh ended before completing every section" >&2; exit 1; fi' EXIT

PASS=0
FAIL=0
exec 3>&1
ok()   { echo "  ok  - $1" >&3; PASS=$((PASS+1)); }
fail() { echo "  FAIL - $1" >&2; FAIL=$((FAIL+1)); }
check() { # <description> <command...>
  local desc="$1"; shift
  if "$@"; then ok "$desc"; else fail "$desc"; fi
}

# --- hermetic environment -----------------------------------------------------
# PATH is a symlink farm of the host tools minus every agent binary, so "binary missing" is real
# even on a machine that has omp / claude / codex / opencode installed.
ISO="$WORK/iso-bin"; STUBS="$WORK/stub-bin"; BISTUBS="$WORK/agent-bin"
mkdir -p "$ISO" "$STUBS" "$BISTUBS"
cat > "$ISO/yq" <<WRAP
#!/usr/bin/env bash
exec python3 "$LIB/_yq.py" "\$@"
WRAP
chmod +x "$ISO/yq"
IFS=: read -r -a _path_dirs <<<"$PATH"
for _d in "${_path_dirs[@]}"; do
  [[ -n "$_d" && -d "$_d" ]] || continue
  for _f in "$_d"/*; do
    _n="${_f##*/}"
    case "$_n" in omp|claude|codex|opencode|yq) continue ;; esac
    [[ -f "$_f" && -x "$_f" ]] || continue
    [[ -e "$ISO/$_n" || -L "$ISO/$_n" ]] || ln -s "$_f" "$ISO/$_n"
  done
done
unset _path_dirs _d _f _n

make_stub() { # <name> : fake agent binary; only its presence on PATH matters for preflight
  printf '#!/usr/bin/env bash\nexit 0\n' > "$BISTUBS/$1"
  chmod +x "$BISTUBS/$1"
}

unset EVAL_RUNNER EVAL_RUNNERS_DIR EVAL_SKIP_AUTH_CHECK EVAL_BYPASS EVAL_STRICT EVAL_REPORTS EVAL_MODEL \
      EVAL_CASE_MODEL EVAL_AB_MODEL_OVERRIDE EVAL_MAX_SECONDS EVAL_STABILITY_SAMPLES EVAL_MODE \
      OPENCODE_MODEL EVAL_SMOKE_MODEL EVAL_FULL_MODEL EVAL_REQUESTED_MODEL \
      ANTHROPIC_API_KEY OPENROUTER_API_KEY OPENAI_API_KEY GOOGLE_GENERATIVE_AI_API_KEY OPENCODE_AUTH_FILE || true
export HOME="$WORK/home"; mkdir -p "$HOME"
export EVAL_STATE_DIR="$WORK/state" OPENCODE_SKILLS_ROOT="$WORK/skills" EVAL_BUDGET_USD=""
export EVAL_TEST_TRACE="$WORK/trace.log"
SKILL="custom-runner-skill"
CASES="$OPENCODE_SKILLS_ROOT/$SKILL/evals/cases"
RUNNERS="$WORK/runners"
mkdir -p "$EVAL_STATE_DIR" "$CASES" "$RUNNERS"
cd "$WORK"
RUN_PATH="$ISO"

# --- fixtures -----------------------------------------------------------------
# Test adapter. Lifecycle is traced; behaviour is driven by runner_config, which the harness passes as
# argument 2 of every subcommand. Mirrors docs/runners.md argv:
#   prepare <workdir> <config>   spawn <workdir> <config> <transcript> [prompt]
#   fingerprint <workdir> <config>   teardown <workdir> <config>
write_adapter() { # <dir> <name>
  cat > "$1/$2.sh" <<'ADAPTER'
#!/usr/bin/env bash
name="$(basename "$0" .sh)"
sub="${1:-}"; shift || true
trace() { printf '%s\n' "$*" >> "${EVAL_TEST_TRACE:?}"; }
workdir="${1:-}"; CFG="${2:-}"; [[ -n "$CFG" ]] || CFG='{}'
flag() { [[ "$(jq -r "$1 // false" <<<"$CFG")" == "true" ]]; }
case "$sub" in
  prepare)
    trace "prepare $workdir"
    if flag .fail_prepare; then echo "prepare refused" >&2; exit 7; fi
    printf '%s' "$workdir" > "$workdir/.prepared"
    ;;
  spawn)
    transcript="${3:-}"
    trace "spawn $workdir runner=${EVAL_RUNNER:-} model=${EVAL_CASE_MODEL:-} case=${EVAL_CASE_ID:-}"
    echo "adapter stdout noise that must never be mistaken for an exit code"
    if flag .hang; then exec sleep 30; fi
    if [[ "$(cat "$workdir/.prepared" 2>/dev/null || true)" != "$workdir" ]]; then
      echo "spawn without prepare for this workdir" >&2; exit 9
    fi
    if ! flag .skip_file; then echo done > "$workdir/made-by-adapter.txt"; fi
    if ! flag .no_transcript; then
      content="$name $(jq -r '.marker // "marker"' <<<"$CFG")"
      case "$name" in
        omp|claude-code|codex)
          # Built-in agent names are scored against the normalized CLI event shape (lib/agent_cli.sh); an
          # override adapter of the same name must write it too, with the runner equal to its own name.
          # legacy_transcript: true deliberately writes the old shape so the scorer's rejection is testable.
          if flag .legacy_transcript; then
            jq -cn --arg c "$content" '{event:"result",content:$c}' > "$transcript"
          else
            jq -cn --arg c "$content" --arg r "$name" '{event:"result",type:"assistant",runner:$r,content:$c,ts:"2000-01-01T00:00:00Z"}' > "$transcript"
          fi
          ;;
        *)
          printf '{"event":"result","content":"%s"}\n' "$content" > "$transcript"
          ;;
      esac
    fi
    exit "$(jq -r '.spawn_rc // 0' <<<"$CFG")"
    ;;
  fingerprint)
    trace "fingerprint $workdir"
    echo "fp-$name"
    ;;
  teardown)
    trace "teardown $workdir"
    if flag .fail_teardown; then exit 5; fi
    ;;
  *) echo "unknown subcommand: $sub" >&2; exit 2 ;;
esac
ADAPTER
  chmod +x "$1/$2.sh"
}

reset_cases() { rm -f "$CASES"/*.yaml; }

write_case() { # <id> <runner|""> <marker> [extra runner_config line...]
  local id="$1" runner="$2" marker="$3"; shift 3
  {
    echo "id: $id"
    echo "description: custom runner case $id"
    if [[ -n "$runner" ]]; then echo "runner: $runner"; fi
    if [[ -n "${CASE_MODEL:-}" ]]; then echo "model: $CASE_MODEL"; fi
    echo "prompt: \"$marker\""
    echo "eval_type: capability"
    echo "compare_to_baseline: false"
    echo "runner_config:"
    echo "  marker: $marker"
    local line
    for line in "$@"; do echo "  $line"; done
    echo "checks:"
    echo "  - kind: output_contains"
    echo "    value: \"$marker\""
    echo "  - kind: file_exists"
    echo "    path: made-by-adapter.txt"
  } > "$CASES/$id.yaml"
}

RC=0; RUN_DIR=""
run_eval() { # <log> [run.sh args...]; sets RC and RUN_DIR (empty when no run directory was created)
  local log="$1" rid; shift
  RC=0
  PATH="$RUN_PATH" bash "$EVAL_BIN" --skill="$SKILL" --trigger=manual "$@" >"$log" 2>&1 || RC=$?
  rid="$(sed -n 's/^\[eval-harness\] run_id=//p' "$log" | head -n 1)"
  RUN_DIR=""
  if [[ -n "$rid" ]]; then RUN_DIR="$EVAL_STATE_DIR/runs/$rid"; fi
}
status_of() { jq -r --arg c "$1" '.cases[] | select(.case_id==$c) | .status' "$RUN_DIR/results.json" 2>/dev/null || true; }
log_has() { grep -qF -- "$2" "$1"; }
trace_has() { grep -qF -- "$1" "$EVAL_TEST_TRACE"; }
trace_reset() { : > "$EVAL_TEST_TRACE"; }
# line number of the first trace line containing the text (0 when absent)
trace_line() { grep -nF -- "$1" "$EVAL_TEST_TRACE" | head -n 1 | cut -d: -f1 || true; }

write_adapter "$RUNNERS" acme-agent
write_adapter "$RUNNERS" other-agent
export EVAL_RUNNERS_DIR="$RUNNERS"

# ==============================================================================
echo "== 1. lib/runner.sh: trusted resolution and opencode dispatch =="
(
  # shellcheck disable=SC1091
  source "$LIB/runner.sh"
  set +e
  resolve_runner "acme-agent" >/dev/null 2>&1; r_ok=$?
  resolve_runner "my-agent_1.2" >/dev/null 2>&1; r_missing=$?
  resolve_runner "../evil" >/dev/null 2>&1; r_up=$?
  resolve_runner "sub/evil" >/dev/null 2>&1; r_slash=$?
  resolve_runner "a..b" >/dev/null 2>&1; r_dots=$?
  resolve_runner ".hidden" >/dev/null 2>&1; r_hidden=$?
  resolve_runner "/etc/passwd" >/dev/null 2>&1; r_abs=$?
  printf '%s %s %s %s %s %s %s\n' "$r_ok" "$r_missing" "$r_up" "$r_slash" "$r_dots" "$r_hidden" "$r_abs"
) > "$WORK/resolve.out"
read -r r_ok r_missing r_up r_slash r_dots r_hidden r_abs < "$WORK/resolve.out"
check "resolve_runner finds a runner in EVAL_RUNNERS_DIR" test "$r_ok" = "0"
check "resolve_runner reports a well-formed but absent runner" test "$r_missing" = "1"
check "resolve_runner rejects '../evil'" test "$r_up" = "2"
check "resolve_runner rejects 'sub/evil'" test "$r_slash" = "2"
check "resolve_runner rejects names containing '..'" test "$r_dots" = "2"
check "resolve_runner rejects a leading dot" test "$r_hidden" = "2"
check "resolve_runner rejects absolute paths" test "$r_abs" = "2"

oc_out="$(bash -c "source '$LIB/runner.sh'; spawn_opencode() { echo \"spawned \$*\"; }; dispatch_runner spawn opencode a b; echo rc=\$?" 2>&1)"
check "dispatch_runner spawn opencode runs spawn_opencode once and does not fall through to a file" \
  test "$oc_out" = $'spawned a b\nrc=0'

SHIPPED_DIR="$(cd "$LIB/.." && pwd)/runners"
for sname in langgraph-node atd-sandbox omp claude-code codex; do
  check "EVAL_RUNNERS_DIR set: shipped adapter '$sname' still resolves" \
    test "$(bash -c "source '$LIB/runner.sh'; resolve_runner '$sname'")" = "$SHIPPED_DIR/$sname.sh"
done
check "EVAL_RUNNERS_DIR set: custom adapter resolves from the override dir" \
  test "$(bash -c "source '$LIB/runner.sh'; resolve_runner 'acme-agent'")" = "$RUNNERS/acme-agent.sh"
check "EVAL_RUNNERS_DIR set: a truly nonexistent adapter still fails" \
  bash -c "source '$LIB/runner.sh'; ! resolve_runner 'no-such-adapter-anywhere' >/dev/null 2>&1"
PREC="$WORK/precedence-runners"; mkdir -p "$PREC"; write_adapter "$PREC" omp
check "trusted EVAL_RUNNERS_DIR adapter takes precedence over the shipped one of the same name" \
  test "$(EVAL_RUNNERS_DIR="$PREC" bash -c "source '$LIB/runner.sh'; resolve_runner omp")" = "$PREC/omp.sh"
EVAL_RUNNERS_DIR="$PREC" bash -c "source '$LIB/runner.sh'; list_runners" > "$WORK/list.out"
check "list_runners: opencode first" test "$(head -n 1 "$WORK/list.out")" = "opencode"
check "list_runners: includes override and shipped adapters" bash -c 'grep -qx omp "$1" && grep -qx langgraph-node "$1" && grep -qx codex "$1"' _ "$WORK/list.out"
check "list_runners: a name present in both directories is listed once" test "$(grep -cx omp "$WORK/list.out")" = "1"

# ==============================================================================
echo "== 2. custom adapter name: full lifecycle, provenance, noisy stdout =="
printf '#!/usr/bin/env bash\n[[ "${1:-}" == "--version" ]] && { echo "opencode 9.9.9"; exit 0; }\necho "{\\"content\\":\\"OC-MARK\\"}"\n' > "$STUBS/opencode"
chmod +x "$STUBS/opencode"
reset_cases; trace_reset
write_case life-1 acme-agent LIFE-MARK
RUN_PATH="$STUBS:$ISO" run_eval "$WORK/t2.log" --case=life-1
check "custom adapter run exits 0" test "$RC" = "0"
check "custom case is graded PASS (stdout noise did not corrupt the exit code)" test "$(status_of life-1)" = "PASS"
check "prepare ran before spawn" test "$(trace_line "prepare $RUN_DIR/life-1/workdir")" -gt 0
check "spawn ran after prepare" test "$(trace_line "spawn $RUN_DIR/life-1/workdir")" -gt "$(trace_line "prepare $RUN_DIR/life-1/workdir")"
check "teardown ran after spawn" test "$(trace_line "teardown $RUN_DIR/life-1/workdir")" -gt "$(trace_line "spawn $RUN_DIR/life-1/workdir")"
check "fingerprint subcommand was dispatched" trace_has "fingerprint $RUN_DIR/life-1/workdir"
check "env manifest records the custom runner and its fingerprint" \
  jq -e '.runner=="acme-agent" and .graph_fingerprint=="fp-acme-agent"' "$RUN_DIR/life-1/env-manifest.json" >/dev/null
check "grading manifest names the custom runner" \
  jq -e '.provenance.runner.name=="acme-agent"' "$RUN_DIR/life-1/grading-manifest.json" >/dev/null
check "grading manifest does not claim the opencode version for a custom runner" \
  jq -e '(.provenance.runner.version | tostring | contains("9.9.9")) | not' "$RUN_DIR/life-1/grading-manifest.json" >/dev/null
check "transcript written by the adapter is bound as available evidence" \
  jq -e '.evidence.transcript.status=="available"' "$RUN_DIR/life-1/grading-manifest.json" >/dev/null
check "custom runner env manifest does not claim an opencode version" \
  jq -e '.opencode_version=="none"' "$RUN_DIR/life-1/env-manifest.json" >/dev/null
check "custom runner without an explicit model records model_id unknown (not the opencode smoke default)" \
  jq -e '.model_id=="unknown"' "$RUN_DIR/life-1/env-manifest.json" >/dev/null
check "grading manifest provenance model_id is unknown too" \
  jq -e '.provenance.model_id=="unknown"' "$RUN_DIR/life-1/grading-manifest.json" >/dev/null

# ==============================================================================
echo "== 3. CLI / EVAL_RUNNER selection when the case names no runner =="
reset_cases; trace_reset
write_case blank-1 "" BLANK-MARK
RUN_PATH="$STUBS:$ISO" run_eval "$WORK/t3a.log" --runner=acme-agent
check "--runner selects a custom adapter for a case without runner:" test "$RC" = "0"
check "blank-runner case PASS through the CLI-selected adapter" test "$(status_of blank-1)" = "PASS"
check "adapter saw EVAL_RUNNER=acme-agent" trace_has "spawn $RUN_DIR/blank-1/workdir runner=acme-agent"
check "env manifest records the CLI-selected runner" jq -e '.runner=="acme-agent"' "$RUN_DIR/blank-1/env-manifest.json" >/dev/null

trace_reset
EVAL_RUNNER=other-agent RUN_PATH="$STUBS:$ISO" run_eval "$WORK/t3b.log"
check "EVAL_RUNNER selects a custom adapter without --runner" test "$RC" = "0"
check "adapter saw EVAL_RUNNER=other-agent" trace_has "spawn $RUN_DIR/blank-1/workdir runner=other-agent"

trace_reset
run_eval "$WORK/t3c.log" --runner=ghost-agent
check "CLI-selected missing adapter fails preflight with exit 13" test "$RC" = "13"
check "preflight names the missing adapter" log_has "$WORK/t3c.log" "runner 'ghost-agent' has no adapter"
check "no case was executed for a missing CLI-selected adapter" test ! -s "$EVAL_TEST_TRACE"

reset_cases; write_case conflict-1 acme-agent CONF-MARK
trace_reset
run_eval "$WORK/t3d.log" --runner=other-agent
check "CLI/case runner disagreement is still an ERROR case (exit 13)" test "$RC" = "13"
check "conflicting case reports ERROR" test "$(status_of conflict-1)" = "ERROR"
check "conflicting case never spawned" test ! -s "$EVAL_TEST_TRACE"

# ==============================================================================
echo "== 4. missing adapter and path traversal =="
reset_cases; write_case miss-1 nope-agent MISS-MARK
run_eval "$WORK/t4a.log"
check "case naming an unregistered runner fails preflight (exit 13)" test "$RC" = "13"
check "missing adapter message" log_has "$WORK/t4a.log" "runner 'nope-agent' has no adapter"

printf '#!/usr/bin/env bash\ntouch "%s"\n' "$WORK/pwned" > "$WORK/evil.sh"
chmod +x "$WORK/evil.sh"
for evil in '../evil' 'sub/evil' '..' "$WORK/evil"; do
  reset_cases; write_case evil-1 "$evil" EVIL-MARK
  trace_reset
  run_eval "$WORK/t4b.log"
  check "case runner '$evil' is rejected (exit 13)" test "$RC" = "13"
  check "case runner '$evil': invalid name reported" log_has "$WORK/t4b.log" "invalid runner name"
  check "case runner '$evil': nothing outside the runners dir executed" test ! -e "$WORK/pwned"
done
reset_cases; write_case evil-2 "" EVIL-MARK
run_eval "$WORK/t4c.log" --runner=../evil
check "--runner=../evil is rejected (exit 13)" test "$RC" = "13"
check "--runner=../evil never executes the escaped script" test ! -e "$WORK/pwned"

# ==============================================================================
echo "== 5. built-in agent names: binary-only preflight, no opencode state =="
for pair in omp:omp claude-code:claude codex:codex; do
  bname="${pair%%:*}"; bbin="${pair##*:}"
  write_adapter "$RUNNERS" "$bname"
  reset_cases; write_case "bi-$bname" "" "BI-MARK-$bname"
  trace_reset
  rm -f "$BISTUBS/$bbin"
  # opencode and its credentials are absent on purpose (no EVAL_SKIP_AUTH_CHECK, empty HOME)
  RUN_PATH="$ISO" run_eval "$WORK/t5-$bname-missing.log" --runner="$bname"
  check "$bname: missing '$bbin' binary fails preflight (exit 13)" test "$RC" = "13"
  check "$bname: failure names the binary" log_has "$WORK/t5-$bname-missing.log" "requires '$bbin' on PATH"
  check "$bname: no case executed without its binary" test ! -s "$EVAL_TEST_TRACE"
  check "$bname: failure is not an opencode credential error" bash -c '! grep -q "credential" "$1"' _ "$WORK/t5-$bname-missing.log"

  make_stub "$bbin"
  RUN_PATH="$BISTUBS:$ISO" run_eval "$WORK/t5-$bname.log" --runner="$bname"
  check "$bname: runs with only its binary on PATH (no opencode, no credentials)" test "$RC" = "0"
  check "$bname: case PASS" test "$(status_of "bi-$bname")" = "PASS"
  check "$bname: adapter dispatched with runner=$bname" trace_has "spawn $RUN_DIR/bi-$bname/workdir runner=$bname"
  check "$bname: provenance runner is $bname" \
    jq -e --arg n "$bname" '.provenance.runner.name==$n' "$RUN_DIR/bi-$bname/grading-manifest.json" >/dev/null
  check "$bname: transcript is one normalized assistant result event carrying this runner and the marker" \
    jq -e -s --arg n "$bname" --arg m "BI-MARK-$bname" \
      'length==1 and (.[0] | .event=="result" and .type=="assistant" and .runner==$n and (.content|type=="string" and contains($m)))' \
      "$RUN_DIR/bi-$bname/transcript.jsonl" >/dev/null

  # The scorer must keep rejecting the legacy transcript shape for a built-in name (fail closed, never PASS).
  reset_cases; write_case "bi-legacy-$bname" "" "BI-MARK-$bname" "legacy_transcript: true"
  RUN_PATH="$BISTUBS:$ISO" run_eval "$WORK/t5-$bname-legacy.log" --runner="$bname"
  check "$bname: legacy-shaped transcript is never graded PASS" test "$(status_of "bi-legacy-$bname")" != "PASS"
  check "$bname: legacy-shaped transcript fails the run (nonzero exit)" test "$RC" != "0"

  rm -f "$RUNNERS/$bname.sh"
  # With the override adapter gone the shipped adapter takes over (EVAL_RUNNERS_DIR adds/overrides, never hides).
  check "$bname: without an override the shipped adapter resolves" \
    test "$(bash -c "source '$LIB/runner.sh'; resolve_runner '$bname'")" = "$SHIPPED_DIR/$bname.sh"
  check "$bname: shipped adapter plus its binary on PATH passes preflight" \
    env PATH="$BISTUBS:$ISO" bash -c "source '$LIB/runner.sh'; preflight_check_adapter_runner '$bname'"
  rm -f "$BISTUBS/$bbin"
done

# ==============================================================================
echo "== 6. mixed runners: no per-case env leakage, builtin opencode unchanged =="
reset_cases; trace_reset
CASE_MODEL=model-a write_case a-custom acme-agent MIX-A
{
  echo "id: b-opencode"
  echo "description: opencode default for a case without runner"
  echo "prompt: \"hello\""
  echo "eval_type: capability"
  echo "compare_to_baseline: false"
  echo "checks:"
  echo "  - kind: output_contains"
  echo "    value: \"OC-MARK\""
} > "$CASES/b-opencode.yaml"
write_case c-other other-agent MIX-C
EVAL_SKIP_AUTH_CHECK=1 RUN_PATH="$STUBS:$ISO" run_eval "$WORK/t6.log"
check "mixed run exits 0" test "$RC" = "0"
check "custom case a PASS" test "$(status_of a-custom)" = "PASS"
check "opencode default case b PASS (not a runner-mismatch ERROR)" test "$(status_of b-opencode)" = "PASS"
check "custom case c PASS after an opencode case" test "$(status_of c-other)" = "PASS"
check "case a adapter saw its own runner" trace_has "spawn $RUN_DIR/a-custom/workdir runner=acme-agent model=model-a case=a-custom"
check "case c adapter saw its own runner and NO model from case a" trace_has "spawn $RUN_DIR/c-other/workdir runner=other-agent model= case=c-other"
check "env manifests carry each case's own runner" bash -c '
  [[ "$(jq -r .runner "$1/a-custom/env-manifest.json")" == acme-agent &&
     "$(jq -r .runner "$1/b-opencode/env-manifest.json")" == opencode &&
     "$(jq -r .runner "$1/c-other/env-manifest.json")" == other-agent ]]' _ "$RUN_DIR"
check "opencode case keeps the opencode version in provenance" \
  jq -e '.provenance.runner.name=="opencode" and (.provenance.runner.version|contains("9.9.9"))' "$RUN_DIR/b-opencode/grading-manifest.json" >/dev/null
check "opencode case never dispatched an adapter" bash -c '! grep -q "case=b-opencode" "$1"' _ "$EVAL_TEST_TRACE"
check "custom case with a case model records exactly that requested model" \
  jq -e '.model_id=="model-a"' "$RUN_DIR/a-custom/env-manifest.json" >/dev/null
check "custom case without a model records unknown and does not inherit the previous case's model" \
  jq -e '.model_id=="unknown"' "$RUN_DIR/c-other/env-manifest.json" >/dev/null
check "opencode case keeps the opencode default model (behavior retained)" \
  jq -e '.model_id=="anthropic/claude-3-5-haiku-latest" and (.opencode_version|contains("9.9.9"))' "$RUN_DIR/b-opencode/env-manifest.json" >/dev/null

# ==============================================================================
echo "== 7. lifecycle failure semantics =="
reset_cases; trace_reset
write_case prep-fail acme-agent PF-MARK "fail_prepare: true"
write_case td-fail acme-agent TD-MARK "fail_teardown: true"
write_case rc-with-transcript acme-agent RC-MARK "spawn_rc: 7"
write_case rc-no-transcript acme-agent RN-MARK "spawn_rc: 7" "no_transcript: true"
write_case no-evidence acme-agent NE-MARK "skip_file: true"
RUN_PATH="$STUBS:$ISO" run_eval "$WORK/t7.log"
check "any ERROR case makes the run exit 13" test "$RC" = "13"
check "failed prepare is an ERROR case" test "$(status_of prep-fail)" = "ERROR"
check "failed prepare is attributed to prepare_failed" \
  jq -e '.checks[0].failed_check_id=="prepare_failed:prep-fail"' "$RUN_DIR/prep-fail/checks.json" >/dev/null
check "agent was not spawned after a failed prepare" bash -c '! grep -q "^spawn .*case=prep-fail" "$1"' _ "$EVAL_TEST_TRACE"
check "teardown still ran after a failed prepare" trace_has "teardown $RUN_DIR/prep-fail/workdir"
check "teardown failure does not change the verdict" test "$(status_of td-fail)" = "PASS"
check "teardown failure is reported as a warning" log_has "$WORK/t7.log" "teardown failed"
check "non-zero spawn exit is ERROR even though the transcript and outputs would grade as PASS" \
  jq -e '.status=="ERROR" and .passed==false and (.checks|length)==1 and .checks[0].failed_check_id=="spawn_failed:rc-with-transcript" and (.checks[0].actual|contains("exit 7 with a partial transcript"))' "$RUN_DIR/rc-with-transcript/checks.json" >/dev/null
check "failed-run case is ERROR in results, never PASS" test "$(status_of rc-with-transcript)" = "ERROR"
check "the failed run really did leave a passing-looking transcript and output (nothing was graded)" \
  bash -c '[[ -s "$1/rc-with-transcript/transcript.jsonl" && -f "$1/rc-with-transcript/workdir/made-by-adapter.txt" ]] && grep -qF RC-MARK "$1/rc-with-transcript/transcript.jsonl"' _ "$RUN_DIR"
check "non-zero spawn exit with empty transcript is ERROR spawn_failed" \
  jq -e '.status=="ERROR" and .checks[0].failed_check_id=="spawn_failed:rc-no-transcript"' "$RUN_DIR/rc-no-transcript/checks.json" >/dev/null
check "missing agent output evidence FAILs instead of passing" test "$(status_of no-evidence)" = "FAIL"
check "unavailable output evidence is reported as missing" \
  jq -e '[.checks[] | select(.kind=="file_exists")][0].actual=="missing"' "$RUN_DIR/no-evidence/checks.json" >/dev/null

reset_cases; trace_reset
write_case slow-1 acme-agent SLOW-MARK "hang: true"
EVAL_MAX_SECONDS=1 RUN_PATH="$STUBS:$ISO" run_eval "$WORK/t7b.log"
check "hung custom adapter is bounded by EVAL_MAX_SECONDS" test "$(status_of slow-1)" = "ERROR"
check "timeout is attributed (exit 124)" \
  jq -e '.checks[0].failed_check_id=="timeout:slow-1"' "$RUN_DIR/slow-1/checks.json" >/dev/null
check "teardown ran after a timed-out spawn" trace_has "teardown $RUN_DIR/slow-1/workdir"

# ==============================================================================
echo "== 8. stability samples re-run the full lifecycle =="
reset_cases; trace_reset
write_case stab-1 acme-agent STAB-MARK "skip_file: true"
RUN_PATH="$STUBS:$ISO" run_eval "$WORK/t8.log" --case=stab-1 --stability-samples=2
check "failing custom case performed stability resampling" \
  jq -e '.performed==true and .samples==2' "$RUN_DIR/stab-1/stability.json" >/dev/null
sw="$RUN_DIR/stab-1/stability/sample-2/workdir"
check "sample workdir was prepared" test "$(trace_line "prepare $sw")" -gt 0
check "sample was spawned after its prepare" test "$(trace_line "spawn $sw")" -gt "$(trace_line "prepare $sw")"
check "sample was torn down after its spawn" test "$(trace_line "teardown $sw")" -gt "$(trace_line "spawn $sw")"
check "primary workdir spawned exactly once" test "$(grep -cF "spawn $RUN_DIR/stab-1/workdir " "$EVAL_TEST_TRACE")" = "1"

reset_cases; trace_reset
write_case stab-3 acme-agent STAB3-MARK "spawn_rc: 7"
RUN_PATH="$STUBS:$ISO" run_eval "$WORK/t8c.log" --case=stab-3 --stability-samples=2
check "stability: failing primary run is ERROR (spawn_failed)" \
  jq -e '.status=="ERROR" and .checks[0].failed_check_id=="spawn_failed:stab-3"' "$RUN_DIR/stab-3/checks.json" >/dev/null
check "stability: a non-zero respawn is a sample ERROR even with a passing-looking transcript" \
  jq -e '.status=="ERROR" and (.checks[0].failed_check_id|startswith("sample_spawn:"))' "$RUN_DIR/stab-3/stability/sample-2/checks.json" >/dev/null
check "stability: that sample did produce a transcript that was not accepted" test -s "$RUN_DIR/stab-3/stability/sample-2/transcript.jsonl"


# ==============================================================================
echo "== 9. stochastic samples re-run the lifecycle per sample =="
reset_cases; trace_reset
{
  echo "id: sto-1"
  echo "runner: acme-agent"
  echo "mode: stochastic"
  echo "samples: 2"
  echo "pass_threshold: 2"
  echo "eval_type: capability"
  echo "compare_to_baseline: false"
  echo "prompt: \"STO-MARK\""
  echo "runner_config:"
  echo "  marker: STO-MARK"
  echo "checks:"
  echo "  - kind: file_exists"
  echo "    path: made-by-adapter.txt"
} > "$CASES/sto-1.yaml"
RUN_PATH="$STUBS:$ISO" run_eval "$WORK/t9.log" --case=sto-1
check "stochastic custom case PASS" test "$(status_of sto-1)" = "PASS"
for s in 1 2; do
  sw="$RUN_DIR/sto-1/stochastic/sample-$s/workdir"
  check "stochastic sample $s: prepare -> spawn -> teardown" \
    bash -c '[[ "$2" -gt 0 && "$3" -gt "$2" && "$4" -gt "$3" ]]' _ "$EVAL_TEST_TRACE" \
      "$(trace_line "prepare $sw")" "$(trace_line "spawn $sw")" "$(trace_line "teardown $sw")"
done

reset_cases; trace_reset
{
  echo "id: sto-2"
  echo "runner: acme-agent"
  echo "mode: stochastic"
  echo "samples: 2"
  echo "pass_threshold: 2"
  echo "eval_type: capability"
  echo "compare_to_baseline: false"
  echo "prompt: \"STO2-MARK\""
  echo "runner_config:"
  echo "  marker: STO2-MARK"
  echo "  spawn_rc: 7"
  echo "checks:"
  echo "  - kind: file_exists"
  echo "    path: made-by-adapter.txt"
} > "$CASES/sto-2.yaml"
RUN_PATH="$STUBS:$ISO" run_eval "$WORK/t9b.log" --case=sto-2
check "stochastic: failing runner never makes the case PASS" test "$(status_of sto-2)" != "PASS"
for s in 1 2; do
  check "stochastic sample $s: non-zero spawn is an ERROR sample despite a passing-looking transcript" \
    jq -e '.status=="ERROR" and (.checks[0].failed_check_id|startswith("sample_spawn:"))' "$RUN_DIR/sto-2/stochastic/sample-$s/checks.json" >/dev/null
  check "stochastic sample $s: the failed run left output that would otherwise pass" test -f "$RUN_DIR/sto-2/stochastic/sample-$s/workdir/made-by-adapter.txt"
done

# ==============================================================================
echo "== 10. model identity: explicit requested model only, never an opencode default =="
manifest_model() { jq -r '.model_id' "$RUN_DIR/$1/env-manifest.json"; }
prov_model()     { jq -r '.provenance.model_id' "$RUN_DIR/$1/grading-manifest.json"; }

reset_cases; trace_reset
write_case m-none acme-agent M-NONE
OPENCODE_MODEL=oc/ambient-default EVAL_REQUESTED_MODEL=stale/leaked RUN_PATH="$STUBS:$ISO" run_eval "$WORK/t10a.log" --case=m-none
check "no model requested: env manifest model_id is unknown despite ambient opencode defaults and a stale env var" test "$(manifest_model m-none)" = "unknown"
check "no model requested: provenance model_id is unknown" test "$(prov_model m-none)" = "unknown"
check "no model requested: adapter saw no EVAL_CASE_MODEL" trace_has "spawn $RUN_DIR/m-none/workdir runner=acme-agent model= case=m-none"

reset_cases
CASE_MODEL=case-model-q write_case m-case acme-agent M-CASE
RUN_PATH="$STUBS:$ISO" run_eval "$WORK/t10b.log" --case=m-case
check "case model: env manifest records it" test "$(manifest_model m-case)" = "case-model-q"
check "case model: provenance records it" test "$(prov_model m-case)" = "case-model-q"

reset_cases
write_case m-cfg acme-agent M-CFG "model: cfg-model-z"
RUN_PATH="$STUBS:$ISO" run_eval "$WORK/t10c.log" --case=m-cfg
check "runner_config.model alone: recorded as the requested model" test "$(manifest_model m-cfg)" = "cfg-model-z"

reset_cases
CASE_MODEL=case-model-q write_case m-both acme-agent M-BOTH "model: cfg-model-z"
RUN_PATH="$STUBS:$ISO" run_eval "$WORK/t10d.log" --case=m-both
check "case model wins over runner_config.model" test "$(manifest_model m-both)" = "case-model-q"

EVAL_AB_MODEL_OVERRIDE=ab-model-1 RUN_PATH="$STUBS:$ISO" run_eval "$WORK/t10e.log" --case=m-both
check "A/B override wins over case model and runner_config.model" test "$(manifest_model m-both)" = "ab-model-1"
check "A/B override is what the adapter was handed" trace_has "spawn $RUN_DIR/m-both/workdir runner=acme-agent model=ab-model-1 case=m-both"

reset_cases
write_case m-cfg-num acme-agent M-NUM "model: 5"
RUN_PATH="$STUBS:$ISO" run_eval "$WORK/t10f.log" --case=m-cfg-num
check "non-string runner_config.model is not recorded as an identity" test "$(manifest_model m-cfg-num)" = "unknown"

# ==============================================================================
echo "== 11. EVAL_RUNNERS_DIR adds adapters without hiding the shipped built-ins =="
printf '#!/usr/bin/env bash\ncat >/dev/null\necho "SHIPPED-CODEX-OK"\n' > "$BISTUBS/codex"
chmod +x "$BISTUBS/codex"
reset_cases; trace_reset
write_case ship-a acme-agent SHIP-A
{
  echo "id: ship-b"
  echo "runner: codex"
  echo "prompt: \"hello shipped codex\""
  echo "eval_type: capability"
  echo "compare_to_baseline: false"
  echo "checks:"
  echo "  - kind: output_contains"
  echo "    value: \"SHIPPED-CODEX-OK\""
} > "$CASES/ship-b.yaml"
RUN_PATH="$BISTUBS:$ISO" run_eval "$WORK/t11.log"
check "custom adapter + shipped codex adapter in one run exit 0" test "$RC" = "0"
check "custom case resolved from EVAL_RUNNERS_DIR PASS" test "$(status_of ship-a)" = "PASS"
check "shipped codex case PASS through the real shipped adapter" test "$(status_of ship-b)" = "PASS"
check "shipped codex transcript came from the stub CLI" grep -qF SHIPPED-CODEX-OK "$RUN_DIR/ship-b/transcript.jsonl"
check "env manifests carry each case's own runner" bash -c '
  [[ "$(jq -r .runner "$1/ship-a/env-manifest.json")" == acme-agent &&
     "$(jq -r .runner "$1/ship-b/env-manifest.json")" == codex ]]' _ "$RUN_DIR"
check "shipped built-in without a requested model records unknown, not an opencode default" \
  jq -e '.model_id=="unknown" and .opencode_version=="none"' "$RUN_DIR/ship-b/env-manifest.json" >/dev/null
check "only the custom adapter appears in the test trace" bash -c 'grep -q "case=ship-a" "$1" && ! grep -q "case=ship-b" "$1"' _ "$EVAL_TEST_TRACE"
rm -f "$BISTUBS/codex"

echo
echo "PASS: $PASS    FAIL: $FAIL"
[[ "$FAIL" == "0" && "$PASS" -gt 0 ]] || exit 1
COMPLETED=1
exit 0
