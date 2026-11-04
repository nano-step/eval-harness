#!/usr/bin/env bash
# atd_stability_resample: run.sh's stability resampling for the atd-sandbox adapter EXECUTES the sandbox
# again (fresh containers, fresh execution ids) instead of re-grading a copied workdir, discards stale or
# planted evidence, and turns a failed respawn into an ERROR sample instead of re-using old files.
# Needs Docker + the pinned image (SKIP otherwise) because run.sh admission runs the real preflight.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/atd/fixture.sh"
source "$ATD_FX_EVAL_DIR/lib/atd_attest.sh"
REPO_ROOT="$(cd "$ATD_FX_EVAL_DIR/../.." && pwd)"

atd_fx_skip_unless_sandbox
for tool in yq jq; do command -v "$tool" >/dev/null 2>&1 || { echo "SKIP: $tool not installed"; exit 0; }; done

TMP="$(mktemp -d -t atd-resample.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
export EVAL_STATE_DIR="$TMP/state" OPENCODE_SKILLS_ROOT="$TMP/skills" EVAL_SKIP_AUTH_CHECK=1 EVAL_BUDGET_USD=""
unset ATD_TRUST ATD_SIGNING_KEY_FILE ATD_ALLOWED_SIGNERS_FILE EVAL_ATD_POLICY DOCKER_HOST EVAL_RUNNERS_DIR || true
mkdir -p "$EVAL_STATE_DIR" "$OPENCODE_SKILLS_ROOT/atd-skill/evals/cases"

atd_fx_new_repo "$TMP/repo"
FX="$TMP/fixtures"; mkdir -p "$FX"
ATD_FX_BASE="$SHA_GOOD" ATD_FX_CANDIDATE="$SHA_REGRESS" atd_fx_case "$FX" "resample" "$ATD_FX_TEST_UPPER_BOUNDARY"
echo '{"planted":"stale evidence from a fixture"}' > "$FX/planted.json"

cat > "$OPENCODE_SKILLS_ROOT/atd-skill/evals/cases/atd-resample.yaml" <<EOF
id: atd-resample
description: stability resampling must re-execute the sandbox
runner: atd-sandbox
prompt: "unused"
eval_type: capability
compare_to_baseline: false
setup:
  fixtures:
    SPEC.md: $FX/SPEC.md
    candidate.json: $FX/candidate.json
    tests/clamp.test.mjs: $FX/tests/clamp.test.mjs
    atd-out/planted.json: $FX/planted.json
runner_config:
  repository: $ATD_FX_REPO
  baseCommit: $SHA_GOOD
  candidateCommit: $SHA_REGRESS
  seed: 7
  testsRel: tests
  timeoutSeconds: 60
checks:
  - kind: file_exists
    path: never-created.txt
EOF

run_eval() { # <log> -> prints run dir
  local log="$1" rid
  bash "$REPO_ROOT/scripts/eval/run.sh" --skill=atd-skill --case=atd-resample --stability-samples=3 --trigger=manual >"$log" 2>&1 || true
  rid="$(sed -n 's/^\[eval-harness\] run_id=//p' "$log" | head -1)"
  printf '%s' "$EVAL_STATE_DIR/runs/$rid"
}

echo "== real sandbox: primary + 2 fresh samples =="
RUN="$(run_eval "$TMP/run1.log")"
CASE="$RUN/atd-resample"
if [[ ! -f "$CASE/stability.json" ]]; then atd_fx_fail "no stability.json: $(tail -5 "$TMP/run1.log")"; atd_fx_finish; fi
jq -e '.performed==true and .samples==3 and (.hashes|length)==3' "$CASE/stability.json" >/dev/null && atd_fx_pass "stability performed with primary + 2 samples" || atd_fx_fail "stability.json: $(cat "$CASE/stability.json")"
ids=()
for d in "$CASE/workdir" "$CASE/stability/sample-2/workdir" "$CASE/stability/sample-3/workdir"; do
  atd_fx_verify_json "$d/atd-out"
  if [[ "$ATD_FX_VRC" != "0" ]]; then atd_fx_fail "evidence in $d does not verify: $ATD_FX_VJSON"; continue; fi
  while IFS= read -r id; do ids+=("$id"); done < <(jq -r '.executionIds[]' <<<"$ATD_FX_VJSON")
  jq -e '.matrix=="PASS->FAIL" and .ehRunId != "unknown" and .caseId=="atd-resample"' <<<"$ATD_FX_VJSON" >/dev/null && atd_fx_pass "$(basename "$(dirname "$d")")/$(basename "$d") verified: PASS->FAIL bound to the case" || atd_fx_fail "binding in $d: $ATD_FX_VJSON"
  [[ ! -e "$d/atd-out/planted.json" ]] && atd_fx_pass "planted fixture evidence did not survive in $d" || atd_fx_fail "planted evidence survived in $d"
done
total="${#ids[@]}"; uniq_count="$(printf '%s\n' "${ids[@]}" | sort -u | wc -l | tr -d ' ')"
[[ "$total" == "6" && "$uniq_count" == "6" ]] && atd_fx_pass "6 distinct executionIds across primary and both samples (no copied stale data)" || atd_fx_fail "executionIds total=$total unique=$uniq_count"
for s in 2 3; do [[ -s "$CASE/stability/sample-$s/transcript.jsonl" ]] && atd_fx_pass "sample-$s has its own transcript" || atd_fx_fail "sample-$s transcript empty"; done
[[ "$(jq -r .matrix "$CASE/stability/sample-2/workdir/atd-out/differential.json")" == "PASS->FAIL" ]] && atd_fx_pass "sample matrix comes from its own execution" || atd_fx_fail "sample matrix"

echo "== failed respawn becomes an ERROR sample, never stale evidence =="
FAKE="$TMP/fakerunners"; mkdir -p "$FAKE"
COUNTER="$TMP/spawn-count"; : > "$COUNTER"
cat > "$FAKE/atd-sandbox.sh" <<EOF
#!/usr/bin/env bash
# Test adapter: the first spawn (primary) publishes evidence; every later spawn fails with no output.
case "\${1:-}" in
  spawn)
    workdir="\$2"; transcript="\$4"
    echo x >> "$COUNTER"
    if [[ "\$(wc -l < "$COUNTER" | tr -d ' ')" == "1" ]]; then
      mkdir -p "\$workdir/atd-out"; echo '{"primary":true}' > "\$workdir/atd-out/marker.json"
      echo '{"event":"result"}' > "\$transcript"; exit 0
    fi
    exit 13 ;;
  fingerprint) echo fake-fingerprint ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$FAKE/atd-sandbox.sh"
RUN2="$(EVAL_RUNNERS_DIR="$FAKE" run_eval "$TMP/run2.log")"
CASE2="$RUN2/atd-resample"
[[ "$(wc -l < "$COUNTER" | tr -d ' ')" == "3" ]] && atd_fx_pass "runner spawned once for the primary and once per sample (3 executions)" || atd_fx_fail "spawn count $(wc -l < "$COUNTER")"
for s in 2 3; do
  [[ ! -e "$CASE2/stability/sample-$s/workdir/atd-out" ]] && atd_fx_pass "sample-$s: copied primary evidence was discarded" || atd_fx_fail "sample-$s kept stale atd-out"
  jq -e '.checks[0].kind=="harness_error" and .status=="ERROR" and (.checks[0].failed_check_id|startswith("sample_spawn:"))' "$CASE2/stability/sample-$s/checks.json" >/dev/null && atd_fx_pass "sample-$s graded as ERROR (sample_spawn), not re-graded from the copy" || atd_fx_fail "sample-$s checks: $(cat "$CASE2/stability/sample-$s/checks.json")"
done
jq -e '.performed==true and .byte_identical==false' "$CASE2/stability.json" >/dev/null && atd_fx_pass "erroring samples make the case non-reproducible (byte_identical=false)" || atd_fx_fail "stability: $(cat "$CASE2/stability.json")"
[[ -f "$CASE2/workdir/atd-out/marker.json" ]] && atd_fx_pass "primary evidence preserved in the primary workdir" || atd_fx_fail "primary evidence missing"

atd_fx_finish
