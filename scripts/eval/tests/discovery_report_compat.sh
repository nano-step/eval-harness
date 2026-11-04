#!/usr/bin/env bash
# Compatibility of discovery cases with results schema 3, verdict precedence, diff.md, JUnit and SARIF.
# Case results come from the real signed-evidence -> score -> manifest -> stability -> build_case_result path.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/atd-fixture.sh
source "$SCRIPT_DIR/lib/atd-fixture.sh"
fx_init
trap 'rm -rf "$FX_TMP"' EXIT
for tool in jq node ssh-keygen; do
  command -v "$tool" >/dev/null 2>&1 || { echo "SKIP: $tool not available" >&2; exit 0; }
done
[[ -f "$FX_EVAL_DIR/lib/atd_attest.sh" ]] || fx_fail "lib/atd_attest.sh (atd_verify) is required"

mk() { # <id> <samples> <sample-args-string|-> <build args...>
  local id="$1" samples="$2" sarg="$3"; shift 3
  local cd; cd="$(fx_case "$id")"
  fx_build "$cd/workdir" "$@"
  if [[ "$sarg" == "-" ]]; then fx_pipeline "$cd" "$samples"; else fx_pipeline "$cd" "$samples" "$sarg"; fi
  fx_result "$cd"
}

CLEAN="$(mk clean 3 - --base=pass --candidate=pass)"
EXPECTED="$(mk expected-change 3 - --base=fail --candidate=pass)"
EXISTING="$(mk existing-failure 3 - --base=fail --candidate=fail)"
VERIFIED="$(mk verified 3 - --base=pass --candidate=fail --review=approved)"
SUSPECTED="$(mk suspected 3 - --base=pass --candidate=fail)"
INCONCLUSIVE="$(mk inconclusive 3 --candidate=pass --base=pass --candidate=fail --review=approved)"
ENVDIFF="$(mk env-incompatible 3 - --base=pass --candidate=fail --review=approved --env-diff)"
TAMPERED_DIR="$(fx_case tampered)"
fx_build "$TAMPERED_DIR/workdir" --base=pass --candidate=fail
printf ' ' >> "$TAMPERED_DIR/workdir/atd-out/base.json"
fx_pipeline "$TAMPERED_DIR" 3 __copy__ __copy__
TAMPERED="$(fx_result "$TAMPERED_DIR")"

# existing check kinds, untouched behaviour
PLAIN_DIR="$FX_TMP/runs/$FX_RUN_ID/plain-fail"; mkdir -p "$PLAIN_DIR/workdir"
cat > "$PLAIN_DIR/case.yaml" <<'YAML'
schema_version: 2
id: plain-fail
eval_type: capability
checks:
  - kind: file_exists
    path: missing.txt
YAML
printf '{"schema_version":4,"model_id":"m"}\n' > "$PLAIN_DIR/env-manifest.json"; : > "$PLAIN_DIR/transcript.jsonl"
run_all_checks "$PLAIN_DIR/case.yaml" "$PLAIN_DIR/workdir" "$PLAIN_DIR/transcript.jsonl" "$PLAIN_DIR/checks.json"
echo '{"samples":1,"byte_identical":true,"hashes":[],"performed":false}' > "$PLAIN_DIR/stability.json"
write_case_grading_manifest "$PLAIN_DIR/case.yaml" "$PLAIN_DIR/workdir" "$PLAIN_DIR/transcript.jsonl" "$PLAIN_DIR/env-manifest.json" "$FX_RUN_ID" plain-fail "$PLAIN_DIR/grading-manifest.json"
PLAIN="$(build_case_result plain-fail "$PLAIN_DIR" "$FX_TMP/none.json")"

# ---- per-case statuses / classes
fx_eq "$(fx_jq "$CLEAN" .status)" PASS "clean"
fx_eq "$(fx_jq "$VERIFIED" .status)" FAIL "verified"
fx_eq "$(fx_jq "$SUSPECTED" .status)" NEEDS_REVIEW "suspected"
fx_eq "$(fx_jq "$INCONCLUSIVE" .status)" INDETERMINATE "inconclusive (flaky sample)"
fx_eq "$(fx_jq "$ENVDIFF" .status)" INDETERMINATE "env incompatible"
fx_eq "$(fx_jq "$TAMPERED" .status)" ERROR "tampered"
fx_eq "$(fx_jq "$PLAIN" .status)" FAIL "existing check kind unchanged"

# ---- schema 3 shape: additive discovery field only
summary() { # <label> <case json...>
  local run_id="$1"; shift
  local arr; arr="$(printf '%s\n' "$@" | jq -s .)"
  build_run_summary "$arr" "$run_id" "ci" "-1"
}
ALL="$(summary run-all "$CLEAN" "$EXPECTED" "$EXISTING" "$VERIFIED" "$SUSPECTED" "$INCONCLUSIVE" "$ENVDIFF" "$PLAIN")"
fx_eq "$(fx_jq "$ALL" .schema_version)" 3 "results schema stays 3"
fx_eq "$(fx_jq "$ALL" '.regression_count // .summary.regression_count')" 0 "discovery never produces stored-baseline regressions"
fx_eq "$(fx_jq "$ALL" '.regressions | length')" 0 "regressions list stays empty"
fx_eq "$(fx_jq "$ALL" '[.cases[].status] | map(select(. as $s | ["PASS","FAIL","ERROR","NEEDS_REVIEW","INDETERMINATE"] | index($s) | not)) | length')" 0 "only existing statuses are used"
fx_eq "$(fx_jq "$ALL" '[.cases[] | keys | join(",")] | unique | length')" 1 "every case (discovery or not) has identical keys"
fx_eq "$(fx_jq "$ALL" '[.cases[] | select(.discovery == null) | .case_id] | sort | join(",")')" "clean,plain-fail" "discovery:null only for clean PASS->PASS and non-discovery cases"
fx_eq "$(fx_jq "$ALL" '.cases[] | select(.case_id=="existing-failure") | .discovery.classification')" EXISTING_FAILURE "existing failure retained in results.json"
fx_eq "$(fx_jq "$ALL" '.cases[] | select(.case_id=="expected-change") | .discovery.classification')" EXPECTED_CHANGE "expected change retained"
fx_eq "$(fx_jq "$ALL" '[.cases[].checks[] | select(.kind=="discovery_finding") | .failed_check_id] | map(select(startswith("discovery_finding:"))) | length')" 7 "discovery check ids carry the matrix"
# distinctions survive in results.json
fx_eq "$(fx_jq "$ALL" '[.cases[] | select(.discovery != null) | .discovery.classification] | unique | sort | join(",")')" "EXISTING_FAILURE,EXPECTED_CHANGE,INCONCLUSIVE,SUSPECTED_REGRESSION,VERIFIED_REGRESSION" "all five classes representable"
fx_eq "$(fx_jq "$ALL" '.cases[] | select(.case_id=="env-incompatible") | .discovery.environmentEqual')" false "equal-environment distinction survives"
fx_eq "$(fx_jq "$ALL" '.cases[] | select(.case_id=="suspected") | .discovery.requirementReason')" semantic_review_missing "no-spec/review distinction survives"
fx_eq "$(fx_jq "$ALL" '.cases[] | select(.case_id=="inconclusive") | .discovery.stability.state')" flaky "flaky distinction survives"
fx_eq "$(fx_jq "$ALL" .verdict)" FAIL "verdict precedence: FAIL over NEEDS_REVIEW/INDETERMINATE"

NO_FAIL="$(summary run-nofail "$CLEAN" "$SUSPECTED" "$INCONCLUSIVE")"
fx_eq "$(fx_jq "$NO_FAIL" .verdict)" NEEDS_REVIEW "suspected -> NEEDS_REVIEW verdict (warn-only exit 0 unless --strict 15)"
INDET="$(summary run-indet "$CLEAN" "$INCONCLUSIVE")"
fx_eq "$(fx_jq "$INDET" .verdict)" INDETERMINATE "inconclusive -> INDETERMINATE verdict"
ERR="$(summary run-err "$CLEAN" "$TAMPERED" "$VERIFIED")"
fx_eq "$(fx_jq "$ERR" .verdict)" ERROR "tampered evidence -> ERROR verdict dominates"
CLEAN_ONLY="$(summary run-clean "$CLEAN" "$EXPECTED" "$EXISTING")"
fx_eq "$(fx_jq "$CLEAN_ONLY" .verdict)" PASS "clean/expected/existing -> PASS"
fx_eq "$(fx_jq "$CLEAN_ONLY" '.summary.pass')" 3 "counts"

# non-PASS discovery cases are retained under warn-only (nothing is dropped from results)
fx_eq "$(fx_jq "$NO_FAIL" '.cases | length')" 3 "warn-only retains every non-PASS case"

# ---- JUnit
well_formed() {
  if command -v xmllint >/dev/null 2>&1; then xmllint --noout "$1"; else python3 -c 'import sys,xml.dom.minidom as m; m.parse(sys.argv[1])' "$1"; fi
}
echo "$ALL" > "$FX_TMP/all.json"
render_junit "$FX_TMP/all.json" > "$FX_TMP/all.xml"
well_formed "$FX_TMP/all.xml" || fx_fail "JUnit XML is not well-formed"
grep -q 'tests="8"' "$FX_TMP/all.xml" || fx_fail "JUnit tests count"
grep -q 'failures="5"' "$FX_TMP/all.xml" || fx_fail "JUnit failures = verified, suspected, inconclusive, env-incompatible, plain-fail"
for needle in 'SUSPECTED_REGRESSION' 'VERIFIED_REGRESSION' 'INCONCLUSIVE' 'incompatible environments'; do
  grep -q "$needle" "$FX_TMP/all.xml" || fx_fail "JUnit lacks '$needle' distinction"
done
grep -q '<testcase name="clean" ' "$FX_TMP/all.xml" || fx_fail "clean testcase"
# PASS cases (clean, expected, existing) have no <failure>
passing="$(awk '/<testcase name="(clean|expected-change|existing-failure)"/{print}' "$FX_TMP/all.xml" | grep -c '</testcase>' || true)"
fx_eq "$passing" 3 "passing discovery cases are plain testcases without failure"
# SUSPECTED message distinct from INCONCLUSIVE message
sus_msg="$(grep -A2 'name="suspected"' "$FX_TMP/all.xml" | grep -o 'message="[^"]*"' | head -1)"
inc_msg="$(grep -A2 'name="inconclusive"' "$FX_TMP/all.xml" | grep -o 'message="[^"]*"' | head -1)"
[[ "$sus_msg" == *SUSPECTED_REGRESSION* && "$inc_msg" == *INCONCLUSIVE* && "$sus_msg" != "$inc_msg" ]] || fx_fail "JUnit messages must distinguish suspected from inconclusive: $sus_msg | $inc_msg"

# ---- SARIF
render_sarif "$FX_TMP/all.json" "0.6.0" > "$FX_TMP/all.sarif"
fx_eq "$(jq -r '.version' "$FX_TMP/all.sarif")" 2.1.0 "SARIF version"
fx_eq "$(jq -r '[.runs[0].results[] | select(.ruleId|startswith("discovery_finding:"))] | length' "$FX_TMP/all.sarif")" 4 "one SARIF result per non-passed discovery check"
fx_eq "$(jq -r '[.runs[0].results[] | select(.ruleId=="discovery_finding:c1:PASS->FAIL")] | length' "$FX_TMP/all.sarif")" 4 "matrix is part of the rule id"
jq -e '.runs[0].results[] | select(.properties.case_id=="suspected") | select(.message.text|test("SUSPECTED_REGRESSION"))' "$FX_TMP/all.sarif" >/dev/null || fx_fail "SARIF message carries classification"
jq -e '.runs[0].results[] | select(.properties.case_id=="plain-fail")' "$FX_TMP/all.sarif" >/dev/null || fx_fail "existing check failures still render"

# ---- diff.md
render_diff_md "$FX_TMP/all.json" "$FX_TMP/diff.md"
grep -q 'SUSPECTED_REGRESSION' "$FX_TMP/diff.md" || fx_fail "diff.md shows suspected finding"
grep -q 'VERIFIED_REGRESSION' "$FX_TMP/diff.md" || fx_fail "diff.md shows verified finding"
grep -q -- '- clean: PASS' "$FX_TMP/diff.md" || fx_fail "diff.md stable section unchanged"
if grep -q '^## REGRESSION' "$FX_TMP/diff.md"; then fx_fail "discovery must never render as a stored-baseline REGRESSION"; fi

# ---- baselines untouched
[[ -z "$(find "$FX_TMP" -name '*.baseline.json' -o -type d -name baselines 2>/dev/null)" ]] || fx_fail "no baseline files may be created"

echo "PASS discovery_report_compat: schema 3, verdict precedence, JUnit, SARIF and diff.md semantics preserved"
