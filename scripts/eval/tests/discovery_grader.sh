#!/usr/bin/env bash
# Behavior tests for discovery_finding / discovery_test_health / Stage B grading and the finalization path.
# Evidence is signed by the REAL attest.mjs signer and graded through the real score.sh -> manifest ->
# stability -> build_case_result sequence (same order as run.sh) and replayed through the real grade.sh.
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

VERIFIED_ARGS=(--base=pass --candidate=fail --review=approved)

run_case() { # <id> <samples> <build args...> ; sample overrides via SAMPLE_ARGS array global
  local id="$1" samples="$2"; shift 2
  local cd; cd="$(fx_case "$id" "${EXTRA_CHECKS:-}")"
  fx_build "$cd/workdir" "$@"
  fx_pipeline "$cd" "$samples" ${SAMPLE_ARGS[@]+"${SAMPLE_ARGS[@]}"}
  printf '%s' "$cd"
}
SAMPLE_ARGS=()

# ---------------------------------------------------------------- 1. clean / expected / existing
cd="$(run_case pass-pass 3 --base=pass --candidate=pass)"
r="$(fx_result "$cd")"
fx_eq "$(fx_jq "$r" .status)" PASS "PASS->PASS case status"
fx_eq "$(fx_jq "$r" .discovery)" null "PASS->PASS has no finding (discovery:null)"
fx_eq "$(fx_check "$r" discovery_finding .status)" PASS "PASS->PASS check"
fx_eq "$(fx_check "$r" discovery_test_health .status)" PASS "healthy test"
fx_eq "$(fx_jq "$r" .stability.performed)" false "no sampling when everything passes"
echo "PASS PASS->PASS yields PASS and discovery:null"

cd="$(run_case fail-pass 3 --base=fail --candidate=pass)"
r="$(fx_result "$cd")"
fx_eq "$(fx_jq "$r" .status)" PASS "FAIL->PASS status"
fx_eq "$(fx_jq "$r" .discovery.classification)" EXPECTED_CHANGE "FAIL->PASS classification"
fx_eq "$(fx_check "$r" discovery_test_health .status)" FAIL "health records that the test failed on base"
echo "PASS FAIL->PASS is EXPECTED_CHANGE"

cd="$(run_case fail-fail 3 --base=fail --candidate=fail)"
r="$(fx_result "$cd")"
fx_eq "$(fx_jq "$r" .status)" PASS "FAIL->FAIL required check passes"
fx_eq "$(fx_jq "$r" .discovery.classification)" EXISTING_FAILURE "FAIL->FAIL classification"
fx_eq "$(fx_check "$r" discovery_test_health .status)" FAIL "optional health FAIL stays visible"
fx_eq "$(fx_jq "$r" .discovery.health.healthy)" false "finding carries test health"
echo "PASS FAIL->FAIL is EXISTING_FAILURE with visible health failure"

# ---------------------------------------------------------------- 2. PASS->FAIL: provisional then verified
cd="$(run_case verified 3 "${VERIFIED_ARGS[@]}")"
fx_eq "$(jq -r '.checks[0].status' "$cd/checks.json")" FAIL "primary check is a provisional FAIL (triggers sampling)"
fx_eq "$(jq -r '.checks[0].discovery.classification' "$cd/checks.json")" SUSPECTED_REGRESSION "a generated failure alone is only SUSPECTED before sampling"
fx_eq "$(jq -r '.checks[0].provisional' "$cd/checks.json")" true "provisional marker"
fx_eq "$(jq -r '.performed' "$cd/stability.json")" true "stability sampling ran"
r="$(fx_result "$cd")"
fx_eq "$(fx_jq "$r" .status)" FAIL "verified case status"
fx_eq "$(fx_jq "$r" .discovery.classification)" VERIFIED_REGRESSION "verified classification"
fx_eq "$(fx_jq "$r" .discovery.reproducible)" true "reproducible"
fx_eq "$(fx_jq "$r" .discovery.stability.state)" verified "stability state"
fx_eq "$(fx_jq "$r" '.discovery.stability.executionIds | length')" 6 "primary + 2 samples = 6 executions"
fx_eq "$(fx_jq "$r" '.discovery.stability.executionIds | unique | length')" 6 "every execution id is fresh"
fx_eq "$(fx_jq "$r" .discovery.severity)" high "severity from check"
fx_eq "$(fx_jq "$r" .discovery.requirementSupported)" true "supported requirement"
fx_eq "$(fx_jq "$r" .discovery.attestation.trust)" local-same-user "trust label from signed attestation"
fx_eq "$(fx_jq "$r" .regression)" false "discovery never emits stored-baseline REGRESSION"
fx_eq "$(fx_jq "$r" .compare_to_baseline)" false "capability case does not compare to baseline"
fx_eq "$(fx_jq "$r" '.discovery.gradingManifest.sha256')" "$(portable_sha256_file "$cd/grading-manifest.json" | cut -d' ' -f1)" "finding bound to the grading manifest digest"
# finding digest is the canonical hash of the finding without the digest field
recomputed="$(printf '%s' "$r" | jq -c '.discovery' | node --input-type=module -e "
import { canonicalize, sha256Hex } from '$FX_EVAL_DIR/discovery/classify.mjs';
let s='';process.stdin.on('data',d=>s+=d).on('end',()=>{const f=JSON.parse(s);const h=f.findingSha256;delete f.findingSha256;console.log(sha256Hex(canonicalize(f))===h?'ok':'bad');});")"
fx_eq "$recomputed" ok "findingSha256 is reproducible"
# every evidence uri is bound in the grading manifest, samples included
while IFS= read -r uri; do
  rel="${uri#*/}"
  [[ "$(jq -r --arg p "$rel" '[.evidence.artifacts[] | select(.path==$p and .status=="available" and (.sha256|length)==64)] | length' "$cd/grading-manifest.json")" == 1 ]] || fx_fail "evidence uri $uri is not bound in the grading manifest"
done < <(fx_jq "$r" '.discovery.evidenceUris[]')
fx_eq "$(jq -r '[.evidence.artifacts[] | select(.path|test("^stability/sample-3/workdir/atd-out/attestation.json.sig$"))] | length' "$cd/grading-manifest.json")" 1 "sample signature bound"
fx_eq "$(jq -r '.evidence.stability.entries | length' "$cd/grading-manifest.json")" 3 "primary + both samples bound in manifest.evidence.stability"
echo "PASS provisional FAIL triggers sampling; VERIFIED only after 3 fresh identical authenticated samples"

# replay through grade.sh uses the same finalizer with manifest-bound stability
set +e; replay="$(bash "$FX_EVAL_DIR/grade.sh" --manifest="$cd/grading-manifest.json" --strict)"; code=$?; set -e
fx_eq "$code" 14 "strict replay of a verified finding exits 14"
fx_eq "$(fx_jq "$replay" .discovery.classification)" VERIFIED_REGRESSION "replay classification"
fx_eq "$(fx_jq "$replay" .status)" FAIL "replay status"
# manifest without stability binding: replay must not promote
jq 'del(.evidence.stability)' "$cd/grading-manifest.json" > "$cd/grading-manifest.nostab.json"
set +e; replay="$(bash "$FX_EVAL_DIR/grade.sh" --manifest="$cd/grading-manifest.nostab.json" --strict)"; code=$?; set -e
fx_eq "$code" 15 "unbound stability => strict exit 15"
fx_eq "$(fx_jq "$replay" .discovery.classification)" SUSPECTED_REGRESSION "replay without bound stability stays suspected"
fx_eq "$(fx_jq "$replay" .status)" NEEDS_REVIEW "replay status never contradicts the classification"
echo "PASS replay through grade.sh never promotes unbound stability"

# unbound / missing grading manifest in the live path
rm -f "$cd/grading-manifest.json"
r="$(fx_result "$cd")"
fx_eq "$(fx_jq "$r" .discovery.classification)" SUSPECTED_REGRESSION "no grading manifest => not VERIFIED"
fx_eq "$(fx_jq "$r" .status)" NEEDS_REVIEW "no grading manifest status"
write_case_grading_manifest "$cd/case.yaml" "$cd/workdir" "$cd/transcript.jsonl" "$cd/env-manifest.json" "$FX_RUN_ID" verified "$cd/grading-manifest.json"
echo "PASS missing grading manifest downgrades"

# ---------------------------------------------------------------- 3. support gating (quote is only a link)
cd="$(run_case no-review 3 --base=pass --candidate=fail)"
fx_eq "$(jq -r '.checks[0].status' "$cd/checks.json")" FAIL "an unsupported PASS->FAIL is still a provisional FAIL so existing sampling re-runs it"
fx_eq "$(jq -r '.performed' "$cd/stability.json")" true "unsupported candidate was sampled"
r="$(fx_result "$cd")"
fx_eq "$(fx_jq "$r" .discovery.classification)" SUSPECTED_REGRESSION "exact quote without trusted review is not VERIFIED"
fx_eq "$(fx_jq "$r" .status)" NEEDS_REVIEW "no review => NEEDS_REVIEW"
fx_eq "$(fx_jq "$r" .discovery.requirementLink.exactQuote)" true "quote matches verbatim"
fx_eq "$(fx_jq "$r" .discovery.requirementReason)" semantic_review_missing "reason survives results.json"
fx_eq "$(fx_jq "$r" .discovery.reproducible)" true "still reproducible"
echo "PASS exact quote alone never yields VERIFIED"

# a test whose assertion CONTRADICTS the quoted requirement still quotes it exactly: no review => suspected
cd="$(run_case contradicting 3 --base=pass --candidate=fail --test-text="import test from 'node:test'; test('t',()=>{ overlap(touching) === true });")"
r="$(fx_result "$cd")"
fx_eq "$(fx_jq "$r" .discovery.classification)" SUSPECTED_REGRESSION "contradicting assertion with exact quote stays suspected"
echo "PASS contradicting assertion with exact quote stays SUSPECTED"

cd="$(run_case rejected-review 3 --base=pass --candidate=fail --review=rejected)"
r="$(fx_result "$cd")"
fx_eq "$(fx_jq "$r" .discovery.classification)" SUSPECTED_REGRESSION "rejected review"
fx_eq "$(fx_jq "$r" .discovery.semanticReview.status)" rejected "rejected review recorded"
cd="$(run_case mismatched-review 3 --base=pass --candidate=fail --review=mismatch)"
r="$(fx_result "$cd")"
fx_eq "$(fx_jq "$r" .discovery.classification)" SUSPECTED_REGRESSION "review bound to other hashes"
fx_eq "$(fx_jq "$r" .discovery.semanticReview.status)" invalid "mismatched review invalid"
cd="$(run_case no-spec 3 --base=pass --candidate=fail --no-spec --review=approved)"
r="$(fx_result "$cd")"
fx_eq "$(fx_jq "$r" .discovery.classification)" SUSPECTED_REGRESSION "missing spec"
fx_eq "$(fx_jq "$r" .status)" NEEDS_REVIEW "missing spec status"
fx_eq "$(fx_jq "$r" .discovery.requirementSupported)" false "missing spec unsupported"
cd="$(run_case no-ref 3 --base=pass --candidate=fail --no-ref --review=approved)"
r="$(fx_result "$cd")"
fx_eq "$(fx_jq "$r" .discovery.requirementReason)" no_requirement_ref "no requirementRef"
fx_eq "$(fx_jq "$r" .discovery.classification)" SUSPECTED_REGRESSION "no requirementRef is suspected"
cd="$(run_case bad-quote 3 --base=pass --candidate=fail --review=approved --quote="Overlap includes shared borders always." --spec-text="Different spec text without that sentence, long enough.")"
r="$(fx_result "$cd")"
fx_eq "$(fx_jq "$r" .discovery.requirementReason)" quote_not_in_spec "quote absent from spec"
fx_eq "$(fx_jq "$r" .discovery.classification)" SUSPECTED_REGRESSION "unsupported quote"
echo "PASS missing/contradictory/unbound intent evidence stays SUSPECTED"

# ---------------------------------------------------------------- 4. stability downgrades
cd="$(run_case unsampled 1 "${VERIFIED_ARGS[@]}")"
r="$(fx_result "$cd")"
fx_eq "$(fx_jq "$r" .discovery.classification)" SUSPECTED_REGRESSION "unsampled PASS->FAIL"
fx_eq "$(fx_jq "$r" .status)" NEEDS_REVIEW "unsampled status"
fx_eq "$(fx_jq "$r" .discovery.reproducible)" false "not reproduced"
fx_eq "$(fx_check "$r" discovery_finding .status)" PENDING "check status PENDING, never a final FAIL"

SAMPLE_ARGS=("--candidate=pass")
cd="$(run_case flaky 3 "${VERIFIED_ARGS[@]}")"
r="$(fx_result "$cd")"
fx_eq "$(fx_jq "$r" .discovery.classification)" INCONCLUSIVE "flaky sample"
fx_eq "$(fx_jq "$r" .status)" INDETERMINATE "flaky status"
fx_eq "$(fx_jq "$r" .discovery.stability.state)" flaky "flaky state recorded"
fx_eq "$(fx_jq "$r" .stability.byte_identical)" false "existing stability metadata shows divergence"

SAMPLE_ARGS=("--base=error")
cd="$(run_case sample-error 3 "${VERIFIED_ARGS[@]}")"
r="$(fx_result "$cd")"
fx_eq "$(fx_jq "$r" .discovery.classification)" INCONCLUSIVE "sample with an execution error"
fx_eq "$(fx_jq "$r" .status)" INDETERMINATE "sample error status"

SAMPLE_ARGS=("__copy__" "__copy__")
cd="$(run_case stale-copy 3 "${VERIFIED_ARGS[@]}")"
r="$(fx_result "$cd")"
fx_eq "$(fx_jq "$r" .discovery.classification)" INCONCLUSIVE "copied primary evidence is not 3 executions"
fx_eq "$(fx_jq "$r" .discovery.stability.state)" reused "reused execution ids detected"
fx_eq "$(fx_jq "$r" .status)" INDETERMINATE "stale copy status"
SAMPLE_ARGS=()
echo "PASS unsampled/flaky/errored/copied samples downgrade"

# ---------------------------------------------------------------- 5. error / environment / missing evidence
cd="$(run_case exec-error 3 --base=error --candidate=fail --error-class=compile)"
r="$(fx_result "$cd")"
fx_eq "$(fx_jq "$r" .discovery.classification)" INCONCLUSIVE "execution error"
fx_eq "$(fx_jq "$r" .discovery.matrix)" ERROR "error matrix"
fx_eq "$(fx_jq "$r" .status)" INDETERMINATE "error status is INDETERMINATE, not ERROR (valid evidence of an infra/test error)"
fx_eq "$(fx_check "$r" discovery_finding .status)" UNAVAILABLE "error check status"
fx_eq "$(fx_check "$r" discovery_test_health .status)" UNAVAILABLE "health unavailable on base error"

cd="$(run_case env-diff 3 --base=pass --candidate=fail --review=approved --env-diff)"
r="$(fx_result "$cd")"
fx_eq "$(fx_jq "$r" .discovery.classification)" INCONCLUSIVE "unequal environments"
fx_eq "$(fx_jq "$r" .discovery.environmentEqual)" false "environmentEqual recomputed from signed records"
fx_eq "$(fx_jq "$r" .status)" INDETERMINATE "env status"
cd="$(run_case image-diff 3 --base=pass --candidate=pass --image-diff)"
r="$(fx_result "$cd")"
fx_eq "$(fx_jq "$r" .discovery.classification)" INCONCLUSIVE "different image digests are not comparable even when both pass"

cd="$(run_case same-commit 3 --base=pass --candidate=fail --review=approved --same-commit)"
r="$(fx_result "$cd")"
fx_eq "$(fx_jq "$r" .discovery.classification)" INCONCLUSIVE "identical revisions on both sides are not a differential"

cd="$(fx_case missing-evidence)"; printf '\n' > "$cd/.fx-args"
fx_pipeline "$cd" 3 __copy__ __copy__
r="$(fx_result "$cd")"
fx_eq "$(fx_jq "$r" .status)" INDETERMINATE "absent evidence"
fx_eq "$(fx_check "$r" discovery_finding .status)" UNAVAILABLE "absent evidence check"
fx_eq "$(fx_jq "$r" .discovery.evidenceStatus)" unavailable "absence is distinct from invalid"
fx_eq "$(fx_jq "$r" .discovery.classification)" INCONCLUSIVE "absence classification"

cd="$(fx_case no-signature)"
fx_build "$cd/workdir" "${VERIFIED_ARGS[@]}"
rm -f "$cd/workdir/atd-out/attestation.json.sig"
fx_pipeline "$cd" 3 __copy__ __copy__
r="$(fx_result "$cd")"
fx_eq "$(fx_jq "$r" .discovery.evidenceStatus)" unavailable "missing signature => unavailable"
fx_eq "$(fx_jq "$r" .status)" INDETERMINATE "missing signature status"
echo "PASS error/equal-environment/missing-evidence distinctions survive"

# ---------------------------------------------------------------- 6. tamper => ERROR
tamper_case() { # <id> <mutation function>
  local id="$1" mut="$2" cd r
  cd="$(fx_case "$id")"
  fx_build "$cd/workdir" "${VERIFIED_ARGS[@]}"
  "$mut" "$cd/workdir"
  fx_pipeline "$cd" 3 __copy__ __copy__
  r="$(fx_result "$cd")"
  fx_eq "$(fx_jq "$r" .status)" ERROR "$id: tampered evidence must be ERROR"
  fx_eq "$(fx_check "$r" discovery_finding .status)" ERROR "$id: check ERROR"
  fx_eq "$(fx_jq "$r" .discovery.evidenceStatus)" invalid "$id: evidenceStatus invalid"
  fx_eq "$(fx_jq "$r" .discovery.classification)" INCONCLUSIVE "$id: never a finding"
  echo "PASS tamper rejected: $id"
}
m_base() { printf ' ' >> "$1/atd-out/base.json"; }
m_diff() { jq -c '.matrix="FAIL->PASS"' "$1/atd-out/differential.json" > "$1/atd-out/d.tmp" && mv "$1/atd-out/d.tmp" "$1/atd-out/differential.json"; }
m_att() { printf ' ' >> "$1/atd-out/attestation.json"; }
m_artifact() { rm -f "$1"/atd-out/artifacts/base.stdout; }
m_extra() { echo x > "$1/atd-out/artifacts/injected.log"; }
m_symlink() { ln -s /etc/hosts "$1/atd-out/artifacts/link"; }
m_test() { printf '// edited\n' >> "$1/tests/t.test.mjs"; }
m_spec() { printf 'Overlap includes edges.\n' >> "$1/SPEC.md"; }
m_manifest() { jq -c '.failureHypothesis="x"' "$1/candidate.json" > "$1/c.tmp" && mv "$1/c.tmp" "$1/candidate.json"; }
m_sig() { printf 'garbage' > "$1/atd-out/attestation.json.sig"; }
m_testmissing() { rm -f "$1/tests/t.test.mjs"; }
for m in base diff att artifact extra symlink test spec manifest sig testmissing; do tamper_case "tamper-$m" "m_$m"; done

# evidence signed by a different (unknown) signer
cd="$(fx_case foreign-signer)"
EVAL_STATE_DIR="$FX_TMP/state-other" fx_build "$cd/workdir" "${VERIFIED_ARGS[@]}"
fx_pipeline "$cd" 3 __copy__ __copy__
r="$(fx_result "$cd")"
fx_eq "$(fx_jq "$r" .status)" ERROR "unknown signer"
fx_eq "$(fx_jq "$r" .discovery.evidenceStatus)" invalid "unknown signer is invalid, not unavailable"

# attestation from another run/case copied into this one
cd="$(fx_case wrong-run)"
fx_build "$cd/workdir" "${VERIFIED_ARGS[@]}" --run-id=another-run
fx_pipeline "$cd" 3 __copy__ __copy__
r="$(fx_result "$cd")"
fx_eq "$(fx_jq "$r" .status)" ERROR "attestation bound to a different run"
cd="$(fx_case wrong-case)"
fx_build "$cd/workdir" "${VERIFIED_ARGS[@]}" --case-id=another-case
fx_pipeline "$cd" 3 __copy__ __copy__
r="$(fx_result "$cd")"
fx_eq "$(fx_jq "$r" .status)" ERROR "attestation bound to a different case"
echo "PASS foreign signer and cross-run attestation rejected"

# an attestation that omits run/case ids cannot bypass the run binding once the current run is known
cd="$(fx_case unbound-run)"
fx_build "$cd/workdir" "${VERIFIED_ARGS[@]}" --no-run-binding
fx_pipeline "$cd" 3 __copy__ __copy__
r="$(fx_result "$cd")"
fx_eq "$(fx_jq "$r" .status)" ERROR "missing ehRunId/caseId must not bypass binding"
fx_eq "$(fx_jq "$r" .discovery.evidenceStatus)" invalid "unbound attestation is invalid"
echo "PASS run/case binding is mandatory when the run is known"

# trust derives from the verifier, never from a self-declared label
cd="$(fx_case trust-bind)"
fx_build "$cd/workdir" "${VERIFIED_ARGS[@]}"
ver="$(_dg_verify "$cd/workdir/atd-out")"
fx_eq "$(fx_jq "$ver" .status)" valid "baseline verification"
TRUST_OUT="$(OUT_DIR="$cd/workdir/atd-out" WORKDIR="$cd/workdir" VER="$ver" node --input-type=module -e "
import { summarizeEvidence } from '$FX_EVAL_DIR/discovery/classify.mjs';
const ver = JSON.parse(process.env.VER);
const run = (v) => summarizeEvidence({ outDir: process.env.OUT_DIR, workdir: process.env.WORKDIR, verify: v });
const same = run(ver);
const upgraded = run({ ...ver, trust: 'ci-secret' });
const noTrust = run({ ...ver, trust: null });
console.log([same.status, same.trust, upgraded.status, noTrust.status, String(noTrust.trust)].join(','));
")"
fx_eq "$TRUST_OUT" "valid,local-same-user,invalid,valid,null" "trust is taken from the verifier; a disagreeing label is rejected, a missing one is never upgraded"
echo "PASS trust cannot be self-upgraded"

# exactly one discovery_finding check per case
cd="$(fx_case multi-check '  - kind: discovery_finding
    required: true')"
fx_build "$cd/workdir" "${VERIFIED_ARGS[@]}"
fx_pipeline "$cd" 3 __copy__ __copy__
r="$(fx_result "$cd")"
fx_eq "$(fx_jq "$r" .status)" ERROR "multiple discovery_finding checks are a configuration error"
fx_eq "$(fx_jq "$r" '[.checks[] | select(.kind=="discovery_finding" and .status=="ERROR")] | length')" 2 "every discovery_finding check reports ERROR"
fx_eq "$(fx_jq "$r" .discovery)" null "no finding is emitted for an ambiguous case"
echo "PASS multiple discovery_finding checks are an explicit ERROR"

# mixed case: a required non-discovery FAIL against a passing baseline is still a stored-baseline REGRESSION
cd="$FX_TMP/runs/$FX_RUN_ID/mixed-regression"; mkdir -p "$cd/workdir"
cat > "$cd/case.yaml" <<'YAML'
schema_version: 2
id: mixed-regression
eval_type: regression
runner: atd-sandbox
prompt: discovery
checks:
  - kind: file_exists
    path: missing.txt
  - kind: discovery_finding
    required: true
YAML
printf '{"schema_version":4,"model_id":"test/model"}\n' > "$cd/env-manifest.json"; : > "$cd/transcript.jsonl"
fx_build "$cd/workdir" --base=pass --candidate=pass
fx_pipeline "$cd" 1
printf '{"passed":true,"env_manifest":{"schema_version":4,"model_id":"test/model"},"checks":[]}\n' > "$FX_TMP/mixed.baseline.json"
baseline_before="$(portable_sha256_file "$FX_TMP/mixed.baseline.json" | cut -d' ' -f1)"
r="$(build_case_result mixed-regression "$cd" "$FX_TMP/mixed.baseline.json")"
fx_eq "$(portable_sha256_file "$FX_TMP/mixed.baseline.json" | cut -d' ' -f1)" "$baseline_before" "grading must not modify the supplied baseline"
fx_eq "$(fx_jq "$r" .status)" FAIL "required file_exists failure"
fx_eq "$(fx_jq "$r" .regression)" true "discovery presence must not suppress the existing baseline regression"
fx_eq "$(fx_check "$r" discovery_finding .status)" PASS "discovery check itself passes (PASS->PASS)"
fx_eq "$(fx_jq "$r" .discovery)" null "clean discovery"
echo "PASS baseline regression semantics unchanged when a discovery check is present"

# ---------------------------------------------------------------- 7. stability evidence tamper
stab_case() {
  local id="$1" cd
  cd="$(run_case "$id" 3 "${VERIFIED_ARGS[@]}")"
  printf '%s' "$cd"
}
cd="$(stab_case stab-sample-file)"
printf ' ' >> "$cd/stability/sample-2/workdir/atd-out/artifacts/base.stdout"
r="$(fx_result "$cd")"
fx_eq "$(fx_jq "$r" .status)" ERROR "tampered sample evidence"
fx_eq "$(fx_jq "$r" .discovery.classification)" INCONCLUSIVE "tampered sample never VERIFIED"
set +e; bash "$FX_EVAL_DIR/grade.sh" --manifest="$cd/grading-manifest.json" --strict >/dev/null; code=$?; set -e
fx_eq "$code" 13 "grade.sh rejects the tampered sample (artifact digest) with exit 13"

cd="$(stab_case stab-json)"
jq '.hashes[1]="0000"' "$cd/stability.json" > "$cd/s.tmp" && mv "$cd/s.tmp" "$cd/stability.json"
r="$(fx_result "$cd")"
fx_eq "$(fx_jq "$r" .status)" ERROR "stability.json edited after manifest"

cd="$(stab_case stab-checks)"
jq '.status="PASS"' "$cd/stability/sample-3/checks.json" > "$cd/c.tmp" && mv "$cd/c.tmp" "$cd/stability/sample-3/checks.json"
r="$(fx_result "$cd")"
fx_eq "$(fx_jq "$r" .status)" ERROR "sample checks edited after manifest"

# raw stability.json that claims success without manifest binding cannot grant VERIFIED
cd="$(run_case stab-unbound 3 --base=pass --candidate=fail --review=approved)"
jq 'del(.evidence.stability)' "$cd/grading-manifest.json" > "$cd/m.tmp" && mv "$cd/m.tmp" "$cd/grading-manifest.json"
r="$(fx_result "$cd")"
fx_eq "$(fx_jq "$r" .discovery.classification)" SUSPECTED_REGRESSION "unbound stability.json cannot grant VERIFIED"
fx_eq "$(fx_jq "$r" .discovery.stability.bound)" false "bound=false recorded"
echo "PASS stability evidence must be authenticated and manifest-bound"

# ---------------------------------------------------------------- 8. Stage B is supporting only
STUB="$FX_TMP/bin"; mkdir -p "$STUB"
cat > "$STUB/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${STUB_LOG:-/dev/null}"
verdict="${TEST_JUDGE_VERDICT:-PASS}"
printf '{"id":"m","type":"message","role":"assistant","content":[{"type":"text","text":"%s\\nreason"}],"stop_reason":"end_turn"}\n' "$verdict"
STUB
chmod +x "$STUB/curl"
export STUB_LOG="$FX_TMP/judge.log" ANTHROPIC_API_KEY="sk-ant-AAAAAAAAAAAAAAAAAAAAAA"
OLD_PATH="$PATH"; PATH="$STUB:$PATH"
EXTRA_CHECKS='  - kind: llm_judge
    required: false
    discovery_review: true
    samples: 1'

export TEST_JUDGE_VERDICT=PASS
cd="$(run_case judge-no-override 3 --base=pass --candidate=fail)"
r="$(fx_result "$cd")"
fx_eq "$(fx_jq "$r" .discovery.classification)" SUSPECTED_REGRESSION "a PASS review cannot promote an unreviewed finding"
fx_eq "$(fx_jq "$r" .discovery.filter.stageB.majority)" PASS "stage B recorded as supporting evidence"
fx_eq "$(fx_jq "$r" .discovery.filter.stageB.pass)" 1 "stage B agreement counts"
fx_eq "$(fx_jq "$r" .status)" NEEDS_REVIEW "optional judge cannot change status"
grep -q 'touching edges' "$STUB_LOG" || fx_fail "judge prompt must contain the generated test source"
grep -q 'PASS->FAIL' "$STUB_LOG" || fx_fail "judge prompt must contain the authenticated execution summary"

export TEST_JUDGE_VERDICT=FAIL
cd="$(run_case judge-no-demote 3 "${VERIFIED_ARGS[@]}")"
r="$(fx_result "$cd")"
fx_eq "$(fx_jq "$r" .discovery.classification)" VERIFIED_REGRESSION "a FAIL review cannot override deterministic evidence"
fx_eq "$(fx_jq "$r" .discovery.filter.stageB.majority)" FAIL "stage B FAIL still recorded"

cd="$(run_case judge-skipped 3 --base=pass --candidate=pass)"
r="$(fx_result "$cd")"
fx_eq "$(fx_check "$r" llm_judge .status)" ABSTAIN "review only runs for PASS->FAIL candidates"
fx_eq "$(fx_jq "$r" .discovery)" null "clean case still has no finding"
PATH="$OLD_PATH"; unset TEST_JUDGE_VERDICT; EXTRA_CHECKS=""
echo "PASS Stage B review is supporting evidence only"

# ---------------------------------------------------------------- 9. configuration + unchanged behavior
cd="$FX_TMP/runs/$FX_RUN_ID/badcfg"; mkdir -p "$cd/workdir"
cat > "$cd/case.yaml" <<'YAML'
schema_version: 2
id: badcfg
eval_type: capability
checks:
  - kind: discovery_finding
    file: /etc/passwd
YAML
: > "$cd/transcript.jsonl"
run_all_checks "$cd/case.yaml" "$cd/workdir" "$cd/transcript.jsonl" "$cd/out.json"
fx_eq "$(jq -r '.status' "$cd/out.json")" ERROR "absolute evidence path is a configuration ERROR"

cd="$FX_TMP/runs/$FX_RUN_ID/plain"; mkdir -p "$cd/workdir"
printf 'x\n' > "$cd/workdir/out.txt"
cat > "$cd/case.yaml" <<'YAML'
schema_version: 2
id: plain
eval_type: capability
checks:
  - kind: file_exists
    path: out.txt
YAML
printf '{"schema_version":4,"model_id":"m"}\n' > "$cd/env-manifest.json"; : > "$cd/transcript.jsonl"
run_all_checks "$cd/case.yaml" "$cd/workdir" "$cd/transcript.jsonl" "$cd/checks.json"
echo '{"samples":1,"byte_identical":true,"hashes":[],"performed":false}' > "$cd/stability.json"
write_case_grading_manifest "$cd/case.yaml" "$cd/workdir" "$cd/transcript.jsonl" "$cd/env-manifest.json" "$FX_RUN_ID" plain "$cd/grading-manifest.json"
fx_eq "$(jq -r '.evidence | has("stability")' "$cd/grading-manifest.json")" false "non-discovery manifests are unchanged"
r="$(build_case_result plain "$cd" "$FX_TMP/none.json")"
fx_eq "$(fx_jq "$r" .status)" PASS "existing check kinds unchanged"
fx_eq "$(fx_jq "$r" .discovery)" null "discovery:null for non-discovery cases"
fx_eq "$(fx_jq "$r" .passed)" true "legacy passed boolean"

# grading never mutates the supplied baseline (checked directly above for the mixed regression case)
echo "PASS existing behavior unchanged; supplied baseline untouched"

# ---------------------------------------------------------------- 10. pure classifier table
node --input-type=module -e "
import { classifyDifferential as c, classifyTestHealth as h } from '$FX_EVAL_DIR/discovery/classify.mjs';
const ok = (cond, msg) => { if (!cond) { console.error('FAIL: ' + msg); process.exit(1); } };
const obs = (n, over = {}) => Array.from({ length: n }, (_, i) => ({ evidenceStatus: 'valid', matrix: 'PASS->FAIL', environmentEqual: true, executionIds: ['b'+i+(over.tag||''), 'c'+i+(over.tag||'')], fingerprint: 'fp', ...over }));
const st = (o = {}) => ({ performed: true, bound: true, tampered: false, byteIdentical: true, samples: 3, observed: obs(3), ...o });
const base = { candidateId: 'x', severity: 'high', base: 'pass', candidate: 'fail', environmentEqual: true, requirementSupported: true, fingerprint: 'fp' };
const run = (o) => c({ ...base, ...o });
const rows = [
  [{ phase: 'score' }, 'SUSPECTED_REGRESSION', 'FAIL', 'provisional'],
  [{ phase: 'score', requirementSupported: false }, 'SUSPECTED_REGRESSION', 'FAIL', 'score unsupported is still provisional'],
  [{ phase: 'final', stability: st() }, 'VERIFIED_REGRESSION', 'FAIL', 'verified'],
  [{ phase: 'final', stability: st(), requirementSupported: false }, 'SUSPECTED_REGRESSION', 'PENDING', 'verified but unsupported'],
  [{ phase: 'final', stability: st({ samples: 2, observed: obs(2) }) }, 'SUSPECTED_REGRESSION', 'PENDING', 'two samples'],
  [{ phase: 'final', stability: st({ bound: false }) }, 'SUSPECTED_REGRESSION', 'PENDING', 'unbound'],
  [{ phase: 'final', stability: { performed: false } }, 'SUSPECTED_REGRESSION', 'PENDING', 'not sampled'],
  [{ phase: 'final', stability: null }, 'SUSPECTED_REGRESSION', 'PENDING', 'null stability'],
  [{ phase: 'final', stability: st({ byteIdentical: false }) }, 'INCONCLUSIVE', 'UNAVAILABLE', 'flaky'],
  [{ phase: 'final', stability: st({ observed: obs(2) }) }, 'INCONCLUSIVE', 'UNAVAILABLE', 'missing sample evidence'],
  [{ phase: 'final', stability: st({ observed: [...obs(2), { ...obs(1)[0], matrix: 'PASS->PASS', fingerprint: 'other' }] }) }, 'INCONCLUSIVE', 'UNAVAILABLE', 'diverged matrix'],
  [{ phase: 'final', stability: st({ observed: [...obs(2), { ...obs(1)[0], evidenceStatus: 'unavailable' }] }) }, 'INCONCLUSIVE', 'UNAVAILABLE', 'sample unavailable'],
  [{ phase: 'final', stability: st({ observed: [...obs(2), { ...obs(1)[0], evidenceStatus: 'invalid', reason: 'bad sig' }] }) }, 'INCONCLUSIVE', 'ERROR', 'sample invalid'],
  [{ phase: 'final', stability: st({ tampered: true }) }, 'INCONCLUSIVE', 'ERROR', 'tampered'],
  [{ phase: 'final', stability: st({ observed: [{ ...obs(1)[0], executionIds: ['b0','c0'] }, { ...obs(1)[0], executionIds: ['b0','c0'] }, { ...obs(1)[0], executionIds: ['b2','c2'] }] }) }, 'INCONCLUSIVE', 'UNAVAILABLE', 'reused ids'],
  [{ phase: 'final', stability: st({ observed: obs(3).map((o) => ({ ...o, environmentEqual: false })) }) }, 'INCONCLUSIVE', 'UNAVAILABLE', 'sample env'],
  [{ phase: 'final', environmentEqual: false, stability: st() }, 'INCONCLUSIVE', 'UNAVAILABLE', 'unequal env'],
  [{ phase: 'final', environmentEqual: null, stability: st() }, 'INCONCLUSIVE', 'UNAVAILABLE', 'unknown env'],
  [{ phase: 'final', candidate: 'error', stability: st() }, 'INCONCLUSIVE', 'UNAVAILABLE', 'error'],
  [{ phase: 'final', base: 'error', candidate: 'error' }, 'INCONCLUSIVE', 'UNAVAILABLE', 'both error'],
  [{ phase: 'final', base: 'fail', candidate: 'fail' }, 'EXISTING_FAILURE', 'PASS', 'FAIL->FAIL'],
  [{ phase: 'final', base: 'fail', candidate: 'pass' }, 'EXPECTED_CHANGE', 'PASS', 'FAIL->PASS'],
  [{ phase: 'final', base: 'pass', candidate: 'pass' }, null, 'PASS', 'PASS->PASS'],
  [{ phase: 'final', evidenceStatus: 'invalid' }, 'INCONCLUSIVE', 'ERROR', 'invalid evidence'],
  [{ phase: 'final', evidenceStatus: 'unavailable' }, 'INCONCLUSIVE', 'UNAVAILABLE', 'unavailable evidence'],
];
for (const [o, cls, status, name] of rows) {
  const r = run(o);
  ok(r.classification === cls, name + ': classification ' + r.classification + ' != ' + cls);
  ok(r.check.status === status, name + ': status ' + r.check.status + ' != ' + status);
  if (cls === null) ok(r.finding === null, name + ': finding must be null');
}
// a model-claimed boolean in the input is ignored: only typed fields count
ok(run({ phase: 'final', stability: st(), specVerified: true, requirementSupported: false }).classification === 'SUSPECTED_REGRESSION', 'model booleans are not trusted');
// stage B never changes the classification
for (const maj of ['PASS', 'FAIL', null]) {
  ok(run({ phase: 'final', stability: st(), stageB: { checkId: 'j', majority: maj, pass: 1, fail: 0, nulls: 0 } }).classification === 'VERIFIED_REGRESSION', 'stageB ' + maj + ' must not demote');
  ok(run({ phase: 'final', stability: st(), requirementSupported: false, stageB: { checkId: 'j', majority: maj, pass: 1, fail: 0, nulls: 0 } }).classification === 'SUSPECTED_REGRESSION', 'stageB ' + maj + ' must not promote');
}
ok(h({ evidenceStatus: 'valid', base: 'fail', candidateId: 'x' }).status === 'FAIL', 'health fail');
ok(h({ evidenceStatus: 'valid', base: 'pass', candidateId: 'x' }).status === 'PASS', 'health pass');
ok(h({ evidenceStatus: 'valid', base: 'error', candidateId: 'x' }).status === 'UNAVAILABLE', 'health error');
ok(h({ evidenceStatus: 'invalid', candidateId: 'x' }).status === 'ERROR', 'health invalid');
console.log('ok');
" | grep -qx ok || fx_fail "pure classifier matrix"
echo "PASS classifyDifferential matrix/status/stability/Stage B table"

echo "PASS discovery_grader: all matrix, status, tamper, spec, stability and replay paths"
