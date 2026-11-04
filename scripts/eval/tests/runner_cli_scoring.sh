#!/usr/bin/env bash
# tests/runner_cli_scoring.sh — output_contains / output_not_contains against transcripts
# written by the omp / claude-code / codex runners, through the real scorer (run_check and
# run_all_checks). Transcripts are produced by the REAL runner scripts driven by PATH shims
# (no provider calls).
#
# Contract under test (lib/score.sh::_score_transcript_scan):
#   * normalized CLI events (runner omp|claude-code|codex, event result, type assistant) are
#     matched against the DECODED response content only: runner/model/ts metadata never matches,
#     escaped quotes/newlines/backslashes/unicode in the real response do match;
#   * matching stays case-sensitive and literal; provenance is the JSONL line of the event;
#   * a transcript recognised as a CLI transcript but malformed fails closed (ERROR);
#   * legacy / OpenCode / custom transcripts keep the raw `grep -F` behaviour.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EVAL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$EVAL_DIR/lib/score.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/eval-cli-scoring-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
ok()   { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1" >&2; }

# --- real runner transcripts through PATH shims --------------------------------
SHIMS="$WORK/shims"; mkdir -p "$SHIMS"
for name in omp claude codex; do
  cat > "$SHIMS/$name" <<'SHIM'
#!/usr/bin/env bash
cat > /dev/null
cat "${SHIM_RESPONSE_FILE:?}"
SHIM
  chmod +x "$SHIMS/$name"
done
export PATH="$SHIMS:$PATH"
unset EVAL_CASE_MODEL EVAL_AB_MODEL_OVERRIDE EVAL_TRANSCRIPT_UNAVAILABLE EVAL_MAX_SECONDS EVAL_RUNNER || true

WD="$WORK/wd"; mkdir -p "$WD"
RESP="$WORK/response.txt"
# Response with an escaped quote, a newline, a backslash and non-ASCII; it never mentions
# the runner name, the model or the word "assistant".
printf 'She said "hello there"\nsecond line C:\\tmp \xc3\xa9\n' > "$RESP"
export SHIM_RESPONSE_FILE="$RESP"

mk_transcript() { # <runner> <out> [model]
  [[ -n "${3-}" ]] && export EVAL_CASE_MODEL="$3" || unset EVAL_CASE_MODEL
  bash "$EVAL_DIR/runners/$1.sh" spawn "$WD" '{}' "$2" "prompt" >/dev/null 2>&1
  unset EVAL_CASE_MODEL
}

mk_check() { # <kind> <value> -> path ; the value is written as a JSON (= YAML double-quoted) string
  local f="$WORK/check.$RANDOM.yaml"
  printf 'kind: %s\nvalue: %s\n' "$1" "$(jq -n --arg v "$2" '$v')" > "$f"
  printf '%s' "$f"
}

# score <kind> <needle> <transcript> -> sets R (json)
score() {
  local f; f="$(mk_check "$1" "$2")"
  R="$(run_check "$f" "$WD" "$3")"
}
expect() { # <desc> <jq-bool-expr>
  if printf '%s' "$R" | jq -e "$2" >/dev/null 2>&1; then ok "$1"; else fail "$1 :: $R"; fi
}

for runner in omp claude-code codex; do
  echo "== $runner =="
  T="$WORK/$runner.jsonl"
  mk_transcript "$runner" "$T" "model-xyz"
  [[ "$(wc -l < "$T" | tr -d ' ')" == "1" ]] || { fail "$runner: runner did not produce a one-line transcript"; continue; }

  # metadata-only needles: present in the raw JSONL, absent from the response.
  for meta in "$runner" "assistant" "result" "model-xyz" "requested_model" "content"; do
    grep -qF -- "$meta" "$T" || { fail "$runner: fixture sanity, raw transcript lacks '$meta'"; continue; }
    score output_contains "$meta" "$T"
    expect "$runner: output_contains '$meta' (metadata only) does NOT pass" '.passed == false and .status == "FAIL"'
    score output_not_contains "$meta" "$T"
    expect "$runner: output_not_contains '$meta' (metadata only) PASSES" '.passed == true and .status == "PASS" and .transcript_span == null'
  done

  # needles really in the decoded response (escaped quote, newline, backslash, unicode)
  score output_contains 'She said "hello there"' "$T"
  expect "$runner: output_contains finds text with an escaped quote" '.passed == true and .transcript_span.start_line == 1 and .transcript_span.end_line == 1'
  score output_not_contains 'She said "hello there"' "$T"
  expect "$runner: output_not_contains FAILS on text with an escaped quote" '.passed == false and .status == "FAIL" and .transcript_span.start_line == 1'
  score output_contains "hello there\"
second" "$T"
  expect "$runner: output_contains matches across the decoded newline" '.passed == true'
  score output_contains 'C:\tmp é' "$T"
  expect "$runner: output_contains matches backslash and unicode literally" '.passed == true'
  score output_contains 'HELLO THERE' "$T"
  expect "$runner: matching stays case-sensitive" '.passed == false'
  score output_contains 'hello.there' "$T"
  expect "$runner: matching stays literal (no regex)" '.passed == false'
  score output_contains 'hello there' "$T"
  expect "$runner: plain substring of the response passes" '.passed == true'
  score output_contains '-hello' "$T"
  expect "$runner: needle with a leading dash is handled" '.passed == false and .status == "FAIL"'
done

echo "== provenance: line number of the matching event =="
cat > "$WORK/two.jsonl" <<'JSONL'
{"event":"result","type":"assistant","runner":"codex","content":"first answer","ts":"2026-01-01T00:00:00Z"}
{"event":"result","type":"assistant","runner":"codex","content":"needle in second","ts":"2026-01-01T00:00:01Z"}
JSONL
score output_contains "needle in second" "$WORK/two.jsonl"
expect "output_contains reports the JSONL line of the event (2)" '.passed == true and .transcript_span.start_line == 2 and .transcript_span.transcript_path != null'
score output_not_contains "needle in second" "$WORK/two.jsonl"
expect "output_not_contains reports the JSONL line of the event (2)" '.passed == false and .transcript_span.start_line == 2 and .transcript_span.end_line == 2'

echo "== fail closed on malformed CLI transcripts =="
bad() { # <name> <content>
  printf '%s\n' "$2" > "$WORK/$1.jsonl"
  for kind in output_contains output_not_contains; do
    score "$kind" "anything" "$WORK/$1.jsonl"
    expect "$1: $kind => ERROR (never PASS)" '.passed == false and .status == "ERROR" and .error == true'
  done
}
bad truncated      '{"event":"result","type":"assistant","runner":"codex","content":"cut off'
bad wrong-event    '{"event":"error","type":"assistant","runner":"omp","content":"anything","ts":"t"}'
bad wrong-type     '{"event":"result","type":"user","runner":"claude-code","content":"anything","ts":"t"}'
bad no-content     '{"event":"result","type":"assistant","runner":"codex","ts":"t"}'
bad non-string     '{"event":"result","type":"assistant","runner":"codex","content":["anything"],"ts":"t"}'
bad empty-content  '{"event":"result","type":"assistant","runner":"codex","content":"","ts":"t"}'
# A bare JSON array has no runner marker, so it is only a CLI transcript when the harness says so.
export EVAL_RUNNER=codex
bad array-line     '["runner","codex"]'
unset EVAL_RUNNER
printf '%s\n%s\n' \
  '{"event":"result","type":"assistant","runner":"codex","content":"ok","ts":"t"}' \
  'not json at all' > "$WORK/second-bad.jsonl"
score output_not_contains "zzz" "$WORK/second-bad.jsonl"
expect "a bad second line fails closed and names its line" '.status == "ERROR" and (.diff_hint | contains("line 2"))'

echo "== EVAL_RUNNER forces normalized validation (no marker needed) =="
# A truncated CLI line that is cut BEFORE the runner field has no marker, so without
# EVAL_RUNNER it autodetects as legacy (raw grep); with EVAL_RUNNER set it must be ERROR.
printf '%s\n' '{"event":"result","type":"assistant","content":"cut off befo' > "$WORK/no-marker.jsonl"
score output_not_contains "forbidden" "$WORK/no-marker.jsonl"
expect "no EVAL_RUNNER: marker-less truncated line is autodetected as legacy (replay behaviour preserved)" '.passed == true and .status == "PASS"'
for forced in omp claude-code codex; do
  export EVAL_RUNNER="$forced"
  for kind in output_contains output_not_contains; do
    score "$kind" "forbidden" "$WORK/no-marker.jsonl"
    expect "EVAL_RUNNER=$forced: truncated CLI JSON lacking the runner key, $kind => ERROR" '.passed == false and .status == "ERROR" and .error == true'
  done
  printf '%s\n' '{"event":"result","type":"assistant","runner":"'"$forced"'","content":"fine answer","ts":"t"}' > "$WORK/good-forced.jsonl"
  score output_contains "fine answer" "$WORK/good-forced.jsonl"
  expect "EVAL_RUNNER=$forced: valid event still scores normally" '.passed == true and .transcript_span.start_line == 1'
  score output_not_contains "$forced" "$WORK/good-forced.jsonl"
  expect "EVAL_RUNNER=$forced: metadata still never matches" '.passed == true and .status == "PASS"'
  printf '%s\n' '{"type":"text","part":{"text":"legacy shaped"}}' > "$WORK/legacy-forced.jsonl"
  score output_not_contains "forbidden" "$WORK/legacy-forced.jsonl"
  expect "EVAL_RUNNER=$forced: a legacy-shaped transcript is not trusted (ERROR)" '.status == "ERROR"'
done
export EVAL_RUNNER=codex
printf '%s\n' '{"event":"result","type":"assistant","runner":"omp","content":"fine answer","ts":"t"}' > "$WORK/other-runner.jsonl"
score output_not_contains "forbidden" "$WORK/other-runner.jsonl"
expect "EVAL_RUNNER=codex: event from a different runner (omp) is rejected" '.status == "ERROR"'
for other in opencode langgraph-node atd-sandbox my-custom; do
  export EVAL_RUNNER="$other"
  score output_not_contains "forbidden" "$WORK/no-marker.jsonl"
  expect "EVAL_RUNNER=$other: non-CLI runner keeps raw grep behaviour" '.passed == true and .status == "PASS"'
done
unset EVAL_RUNNER

echo "== legacy / OpenCode / custom transcripts keep raw grep -F semantics =="
cat > "$WORK/legacy.jsonl" <<'JSONL'
{"type":"text","part":{"text":"hello legacy world"}}
{"event":"step","type":"stdout","content":"custom adapter says codex","ts":"t"}
{"event":"result","type":"assistant","runner":"my-custom-agent","content":"x","ts":"t"}
JSONL
score output_contains 'hello legacy world' "$WORK/legacy.jsonl"
expect "legacy: text on line 1 found" '.passed == true and .transcript_span.start_line == 1'
score output_contains '"type":"text"' "$WORK/legacy.jsonl"
expect "legacy: raw JSON metadata still matches (unchanged)" '.passed == true'
score output_contains 'custom adapter says codex' "$WORK/legacy.jsonl"
expect "legacy: mention of 'codex' in a custom event is not mistaken for a CLI transcript" '.passed == true and .transcript_span.start_line == 2'
score output_not_contains 'my-custom-agent' "$WORK/legacy.jsonl"
expect "legacy: unknown runner name is raw-matched" '.passed == false and .transcript_span.start_line == 3'
score output_not_contains 'absent text' "$WORK/legacy.jsonl"
expect "legacy: absence passes" '.passed == true and .status == "PASS"'
printf 'plain text with \\"runner\\":\\"codex\\" escaped inside a legacy line\n' > "$WORK/escaped-legacy.jsonl"
grep -qF '\"runner\":\"codex\"' "$WORK/escaped-legacy.jsonl" || fail "fixture sanity: escaped marker missing"
score output_contains 'escaped inside' "$WORK/escaped-legacy.jsonl"
expect "legacy: escaped runner marker inside text does not switch modes" '.passed == true and .transcript_span.start_line == 1'
score output_contains 'whatever' "$WORK/does-not-exist.jsonl"
expect "missing transcript: output_contains fails (unchanged)" '.passed == false and .status == "FAIL"'

echo "== end to end through run_all_checks =="
T="$WORK/e2e.jsonl"
mk_transcript codex "$T" "model-xyz"
cat > "$WORK/case.yaml" <<'YAML'
schema_version: 2
id: cli-scoring
eval_type: regression
checks:
  - kind: output_contains
    value: 'She said "hello there"'
  - kind: output_not_contains
    value: 'codex'
  - kind: output_not_contains
    value: 'model-xyz'
YAML
run_all_checks "$WORK/case.yaml" "$WD" "$T" "$WORK/all.json" >/dev/null 2>&1 || true
if jq -e '.status == "PASS" and .passed == true and (.checks | length) == 3' "$WORK/all.json" >/dev/null 2>&1; then
  ok "run_all_checks: real codex transcript PASSES (response match; metadata-only forbidden words absent)"
else
  fail "run_all_checks aggregate :: $(cat "$WORK/all.json" 2>/dev/null)"
fi
cat > "$WORK/case-bad.yaml" <<'YAML'
schema_version: 2
id: cli-scoring-bad
eval_type: regression
checks:
  - kind: output_not_contains
    value: 'forbidden'
YAML
printf '%s\n' '{"event":"result","type":"assistant","runner":"codex","content":"cut' > "$WORK/e2e-bad.jsonl"
run_all_checks "$WORK/case-bad.yaml" "$WD" "$WORK/e2e-bad.jsonl" "$WORK/all-bad.json" >/dev/null 2>&1 || true
if jq -e '.status == "ERROR" and .passed == false' "$WORK/all-bad.json" >/dev/null 2>&1; then
  ok "run_all_checks: malformed CLI transcript makes the case ERROR, not PASS"
else
  fail "run_all_checks malformed :: $(cat "$WORK/all-bad.json" 2>/dev/null)"
fi

echo
echo "== summary =="
echo "  passed: $PASS  failed: $FAIL"
if [[ "$FAIL" -gt 0 ]]; then
  echo "FAIL: runner_cli_scoring" >&2
  exit 1
fi
echo "PASS: runner_cli_scoring"
