#!/usr/bin/env bash
# Jev gate + repair-request behaviour with a stubbed pipeline (run.mjs replaced by a canned-round replayer) over
# REAL signed evidence: the finding/trust that gates and repair requests rely on is recomputed by grade.sh from the
# preserved grading manifests, never read from results.json. Covers: warn-only never blocks but never claims
# success for errors/inconclusive runs, block exits 14 only for recomputed verified + independently signed
# regressions, bounded distinct repair requests, exhausted attempts, preserved artifacts, and the attacks
# (forged results.json, tampered artifact, missing signature/manifest, tampered stability metadata).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISCOVERY_DIR="$SCRIPT_DIR/../discovery"
for tool in jq node git ssh-keygen yq; do command -v "$tool" >/dev/null 2>&1 || { echo "SKIP: $tool required" >&2; exit 0; }; done

# shellcheck source=lib/atd-fixture.sh
source "$SCRIPT_DIR/lib/atd-fixture.sh"
fx_init
WORK="$FX_TMP/work"; mkdir -p "$WORK"
trap 'rm -rf "$FX_TMP"' EXIT
# shellcheck source=lib/discovery_stub_round.sh
source "$SCRIPT_DIR/lib/discovery_stub_round.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
contains() { grep -qF -- "$2" <<<"$1" || fail "expected output to contain: $2
--- output ---
$1"; }
lacks() { if grep -qF -- "$2" <<<"$1"; then fail "output must not contain: $2
--- output ---
$1"; fi; }

KEYS="$WORK/keys"; make_independent_keys "$KEYS"

# Full copy of scripts/eval (without tests) so grade.sh, its libs and the signer/verifier resolve exactly as in
# production; only run.mjs is replaced by the canned-round stub.
mkdir -p "$WORK/eval"
cp -R "$FX_EVAL_DIR/." "$WORK/eval/"
rm -rf "$WORK/eval/tests"
STUB="$WORK/eval/discovery"
install_stub_run_mjs "$STUB"

# gate <scenario-dir> <args...>; prints output, records rc in $RC. The independent allowed-signers file is what an
# operator/CI provides to the verifier; it never comes from the evidence.
gate() {
  local scenario="$1"; shift
  set +e
  OUTPUT="$(STUB_SCENARIO="$scenario" ATD_ALLOWED_SIGNERS_FILE="$KEYS/allowed" bash "$STUB/jev-gate.sh" "$@" 2>&1)"
  RC=$?
  set -e
}

REPO="$WORK/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q -b main
commit_empty() { git -C "$REPO" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m "$1"; git -C "$REPO" rev-parse HEAD; }
C1="$(commit_empty one)"; C2="$(commit_empty two)"; C3="$(commit_empty three)"; C4="$(commit_empty four)"
export SCENARIO_BASE_COMMIT="$C1" SCENARIO_CANDIDATE_COMMIT="$C2"
printf '# spec\n' > "$WORK/SPEC.md"
COMMON=(--repo="$REPO" --base="$C1" --spec="$WORK/SPEC.md")

# 1. argument errors
set +e; OUTPUT="$(bash "$STUB/jev-gate.sh" 2>&1)"; RC=$?; set -e
[[ "$RC" == "2" ]] || fail "missing args must exit 2 (got $RC)"
set +e; OUTPUT="$(bash "$STUB/jev-gate.sh" "${COMMON[@]}" --mode=bogus 2>&1)"; RC=$?; set -e
[[ "$RC" == "2" ]] || fail "bad mode must exit 2 (got $RC)"

# 2. warn mode: SUSPECTED never blocks, is preserved, and is not called a pass
S_SUSPECT="$WORK/s-suspect"; scenario_from_kind "$S_SUSPECT" suspected
gate "$S_SUSPECT" "${COMMON[@]}" --candidate="$C2" --out="$WORK/out-suspect"
[[ "$RC" == "0" ]] || fail "warn mode must exit 0 (got $RC): $OUTPUT"
contains "$OUTPUT" "classifications: SUSPECTED_REGRESSION=1"
contains "$OUTPUT" "NOT A PASS CLAIM"
contains "$OUTPUT" "non-PASS cases preserved: 1"
contains "$OUTPUT" "independently-verified-regressions=0"
lacks "$OUTPUT" "no regression observed"
lacks "$OUTPUT" "repair request:"
[[ "$(jq -r '.mode' "$WORK/out-suspect/round-001/gate.json")" == "warn" ]] || fail "gate.json mode"

# 3. warn mode: pipeline error and missing summary stay exit 0 but are loudly not-a-pass
S_ERR="$WORK/s-error"; scenario_from_kind "$S_ERR" harness-error
gate "$S_ERR" "${COMMON[@]}" --candidate="$C2" --out="$WORK/out-error"
[[ "$RC" == "0" ]] || fail "warn mode error must exit 0 (got $RC)"
contains "$OUTPUT" "status: harness_error"
contains "$OUTPUT" "NOT A PASS CLAIM"
gate none "${COMMON[@]}" --candidate="$C2" --out="$WORK/out-none"
[[ "$RC" == "0" ]] || fail "warn mode without summary must exit 0 (got $RC)"
contains "$OUTPUT" "NOT A PASS CLAIM"
contains "$OUTPUT" "pipeline_error"

# 4. clean run is reported without a success overclaim
S_CLEAN="$WORK/s-clean"; scenario_from_kind "$S_CLEAN" clean
gate "$S_CLEAN" "${COMMON[@]}" --candidate="$C2" --out="$WORK/out-clean"
[[ "$RC" == "0" ]] || fail "clean must exit 0 (got $RC): $OUTPUT"
contains "$OUTPUT" "not proof the change is bug-free"
lacks "$OUTPUT" "NOT A PASS CLAIM"

# 5. genuinely verified but only locally signed: advisory, never a repair request, never blocks
S_LOCAL="$WORK/s-local"; scenario_from_kind "$S_LOCAL" verified-local
gate "$S_LOCAL" "${COMMON[@]}" --candidate="$C2" --out="$WORK/out-local" --mode=block
[[ "$RC" == "0" ]] || fail "block mode must not block on a local-same-user attestation (got $RC): $OUTPUT"
contains "$OUTPUT" "advisory"
lacks "$OUTPUT" "repair request:"
[[ -z "$(ls "$WORK/out-local/repair"/repair-*.json 2>/dev/null || true)" ]] || fail "no repair request may exist for local-same-user"

# 6. block mode, recomputed verified + independently signed: exit 14, bounded distinct requests
S_IND="$WORK/s-independent"; scenario_from_kind "$S_IND" verified-independent
gate "$S_IND" "${COMMON[@]}" --approval-dir="$(scenario_approvals "$S_IND")" --candidate="$C2" --out="$WORK/out-block" --mode=block --max-attempts=3
[[ "$RC" == "14" ]] || fail "block mode must exit 14 for a recomputed independently attested regression (got $RC): $OUTPUT"
contains "$OUTPUT" "independently-verified-regressions=1"
contains "$OUTPUT" "repair request:"
contains "$OUTPUT" "attempt=1/3"
REQ1="$(ls "$WORK/out-block/repair"/repair-*-a1.json)"
jq -e '.schema=="atd.repair-request/v1" and .classification=="VERIFIED_REGRESSION" and .maxAttempts==3 and .attempt==1 and .attestationTrust=="separate-user" and (.failureExcerpt|length)<=4200 and (.failureExcerpt|contains("stdout of candidate")) and .requirementRef.quote!=null' "$REQ1" >/dev/null || fail "repair request content invalid: $(cat "$REQ1")"
REQ1_SHA="$(cksum < "$REQ1")"
jq -e '.verification.cases[0].recomputed==true and .verification.cases[0].consistent==true and .verification.cases[0].trust=="separate-user" and (.independentVerified|length)==1' "$WORK/out-block/round-001/repair-recommendation.json" >/dev/null || fail "recomputed verification record"

# same candidate commit again: idempotent, no new attempt
gate "$S_IND" "${COMMON[@]}" --approval-dir="$(scenario_approvals "$S_IND")" --candidate="$C2" --out="$WORK/out-block" --mode=block --max-attempts=3
[[ "$RC" == "14" ]] || fail "repeat must still block"
[[ -z "$(ls "$WORK/out-block/repair"/repair-*-a2.json 2>/dev/null || true)" ]] || fail "same commit must not consume another attempt"

# attempt accounting across commits: the evidence is attested for C2 only, so earlier attempts are seeded in a fresh
# ledger exactly as previous gate rounds (other commits) would have written them.
REGKEY="$(jq -r .regressionKey "$REQ1")"
seed_ledger() { # <out dir> <count>
  mkdir -p "$1/repair"; : > "$1/repair/ledger.ndjson"
  for i in $(seq 1 "$2"); do jq -nc --arg k "$REGKEY" --argjson i "$i" '{regressionKey:$k,status:"issued",attempt:$i,findingId:"prior",candidateCommit:("prior-commit-"+($i|tostring)),requestPath:"/nonexistent",at:"2026-11-03T00:00:00Z"}' >> "$1/repair/ledger.ndjson"; done
}
seed_ledger "$WORK/out-attempts" 2
gate "$S_IND" "${COMMON[@]}" --approval-dir="$(scenario_approvals "$S_IND")" --candidate="$C2" --out="$WORK/out-attempts" --mode=block --max-attempts=3
contains "$OUTPUT" "attempt=3/3"
seed_ledger "$WORK/out-exhausted" 3
gate "$S_IND" "${COMMON[@]}" --approval-dir="$(scenario_approvals "$S_IND")" --candidate="$C2" --out="$WORK/out-exhausted" --mode=block --max-attempts=3
contains "$OUTPUT" "REPAIR ATTEMPTS EXHAUSTED"
lacks "$OUTPUT" "repair request:"
[[ -z "$(ls "$WORK/out-exhausted/repair"/repair-*.json 2>/dev/null || true)" ]] || fail "an exhausted regression must not get a new request"
[[ "$(cksum < "$REQ1")" == "$REQ1_SHA" ]] || fail "earlier repair request was overwritten"
[[ -f "$WORK/out-block/round-001/results.json" && -f "$WORK/out-block/round-002/results.json" ]] || fail "per-round records must be preserved"

# stale evidence: valid old signed evidence must never be relabelled as the new commit and spends no attempt
gate "$S_IND" "${COMMON[@]}" --approval-dir="$(scenario_approvals "$S_IND")" --candidate="$C3" --out="$WORK/out-stale" --mode=block --max-attempts=3
contains "$OUTPUT" "STALE EVIDENCE"
lacks "$OUTPUT" "repair request:"
[[ "$RC" == "0" ]] || fail "stale evidence must not block the newer commit (got $RC): $OUTPUT"
[[ ! -s "$WORK/out-stale/repair/ledger.ndjson" ]] || fail "stale evidence must not spend an attempt"

# a corrupt ledger fails closed instead of silently resetting attempt accounting
mkdir -p "$WORK/out-corrupt/repair"; printf '{"regressionKey":"%s","status":"issued","candidateCommit":"x"}\nthis is not json\n' "$REGKEY" > "$WORK/out-corrupt/repair/ledger.ndjson"
gate "$S_IND" "${COMMON[@]}" --approval-dir="$(scenario_approvals "$S_IND")" --candidate="$C2" --out="$WORK/out-corrupt" --mode=block --max-attempts=3
contains "$OUTPUT" "ledger_corrupt"
[[ "$RC" == "13" ]] || fail "a corrupt ledger must exit 13 in block mode (got $RC)"
[[ -z "$(ls "$WORK/out-corrupt/repair"/repair-*.json 2>/dev/null || true)" ]] || fail "a corrupt ledger must not produce a request"

# 7. block mode never fails on suspected/inconclusive, and fails closed on pipeline errors
gate "$S_SUSPECT" "${COMMON[@]}" --candidate="$C2" --out="$WORK/out-b2" --mode=block
[[ "$RC" == "0" ]] || fail "block mode must not fail for SUSPECTED only (got $RC)"
S_INC="$WORK/s-inconclusive"; scenario_from_kind "$S_INC" inconclusive
gate "$S_INC" "${COMMON[@]}" --candidate="$C2" --out="$WORK/out-b2i" --mode=block
[[ "$RC" == "0" ]] || fail "block mode must not fail for INCONCLUSIVE only (got $RC): $OUTPUT"
contains "$OUTPUT" "NOT A PASS CLAIM"
gate "$S_ERR" "${COMMON[@]}" --candidate="$C2" --out="$WORK/out-b3" --mode=block
[[ "$RC" == "13" ]] || fail "block mode must exit 13 when the pipeline errored (got $RC)"
gate none "${COMMON[@]}" --candidate="$C2" --out="$WORK/out-b4" --mode=block
[[ "$RC" == "13" ]] || fail "block mode without a summary must exit 13 (got $RC)"

# 8. forged / tampered inputs: nothing self-declared can promote, block or repair
attack() { # <name> <mutator> [kind] -> runs a block-mode gate over the attacked round; asserts no block, no request
  local name="$1" mutator="$2" kind="${3:-verified-independent}" d="$WORK/attack-$1"
  scenario_from_kind "$d" "$kind"
  "$mutator" "$d"
  gate "$d" "${COMMON[@]}" --candidate="$C2" --out="$WORK/out-attack-$name" --mode=block --approval-dir="$(scenario_approvals "$d")"
  [[ "$RC" == "13" || "$RC" == "0" ]] || fail "attack '$name' must not block as a verified regression (rc=$RC): $OUTPUT"
  [[ -z "$(ls "$WORK/out-attack-$name/repair"/repair-*.json 2>/dev/null || true)" ]] || fail "attack '$name' produced a repair request"
  contains "$OUTPUT" "independently-verified-regressions=0"
  ATTACK_OUTPUT="$OUTPUT"; ATTACK_RC="$RC"; ATTACK_DIR="$d"
}
forge_local_as_ci() { forge_results_to_verified "$1" ci-secret; }
attack forged-trust forge_local_as_ci verified-local
contains "$ATTACK_OUTPUT" "UNVERIFIED"; contains "$ATTACK_OUTPUT" "disagrees with the recomputed grading"
[[ "$ATTACK_RC" == "13" ]] || fail "forged trust: block mode must fail closed (13), got $ATTACK_RC"
forge_suspected_as_verified() { forge_results_to_verified "$1" separate-user; }
attack forged-promotion forge_suspected_as_verified suspected
contains "$ATTACK_OUTPUT" "disagrees with the recomputed grading"
attack tampered-artifact tamper_artifact
contains "$ATTACK_OUTPUT" "UNVERIFIED"; contains "$ATTACK_OUTPUT" "independent grading failed"
attack missing-signature drop_signature
contains "$ATTACK_OUTPUT" "UNVERIFIED"
attack missing-manifest drop_manifest
contains "$ATTACK_OUTPUT" "preserved grading manifest is missing"
attack tampered-stability tamper_stability
contains "$ATTACK_OUTPUT" "UNVERIFIED"
# a verifier without the independent allowed-signers cannot confirm an external signature
S_NOSIG="$WORK/s-no-allowed"; scenario_from_kind "$S_NOSIG" verified-independent
set +e; OUTPUT="$(STUB_SCENARIO="$S_NOSIG" env -u ATD_ALLOWED_SIGNERS_FILE bash "$STUB/jev-gate.sh" "${COMMON[@]}" --candidate="$C2" --out="$WORK/out-no-allowed" --mode=block --approval-dir="$(scenario_approvals "$S_NOSIG")" 2>&1)"; RC=$?; set -e
[[ "$RC" != "14" ]] || fail "independent evidence without the verifier's allowed signers must not block"
contains "$OUTPUT" "independently-verified-regressions=0"

# 9. the unsigned preserved manifest/review/case are hash-bound only: an attacker who rewrites BOTH a file and the manifest
#    must still not obtain an independent promotion, and an injected grader must never execute on the host.
SENTINEL="$WORK/host-command-ran"
adv_check() { # <name> <expected-reason-substring>: the round's recomputation record shows VERIFIED-by-grader but not independent
  local rec; rec="$(ls "$WORK/out-attack-$1"/round-001/repair-recommendation.json)"
  jq -e '.independentVerified|length==0' "$rec" >/dev/null || fail "$1: independentVerified must be empty"
  jq -e --arg r "$2" '[.advisories[]?.reason]|any(contains($r))' "$rec" >/dev/null || fail "$1: expected an advisory mentioning '$2': $(jq -c '.advisories' "$rec")"
  [[ -z "$(ls "$WORK/out-attack-$1/repair"/repair-*.json 2>/dev/null || true)" ]] || fail "$1: produced a repair request"
}
attack forged-review-and-manifest forge_review_manifest_results suspected-independent
jq -e '.verification.cases[0].classification=="VERIFIED_REGRESSION" and .verification.cases[0].independent==false' "$WORK/out-attack-forged-review-and-manifest/round-001/repair-recommendation.json" >/dev/null \
  || fail "the forged review must reach the grader as VERIFIED yet stay non-independent: $(jq -c '.verification.cases' "$WORK/out-attack-forged-review-and-manifest/round-001/repair-recommendation.json")"
adv_check forged-review-and-manifest "no operator review for candidate"
contains "$ATTACK_OUTPUT" "advisory"
attack rewritten-review-and-manifest rewrite_review_manifest verified-independent
adv_check rewritten-review-and-manifest "differs from the operator's original"
inject_and_check() { inject_command_check "$1"; }
rm -f "$SENTINEL"
attack injected-command-check inject_and_check verified-independent
[[ ! -e "$SENTINEL" ]] || fail "an injected grader executed a command on the host"
contains "$ATTACK_OUTPUT" "outside the discovery allowlist"

# manifest-selected alternate case file / workdir: the rewritten (hash-only) manifest points grade.sh at files the allowlist
# inspection would never see. The generated bindings are enforced before grading, so nothing runs and nothing is promoted.
rm -f "$SENTINEL"
attack alt-case-path redirect_manifest_case_path verified-independent
[[ ! -e "$SENTINEL" ]] || fail "a manifest-selected alternate case file executed a command on the host"
contains "$ATTACK_OUTPUT" "is not the generated 'case.yaml'"
attack alt-workdir redirect_manifest_workdir verified-independent
contains "$ATTACK_OUTPUT" "is not the generated 'workdir'"
attack symlinked-case symlink_case_file verified-independent
[[ ! -e "$SENTINEL" ]] || fail "a symlinked case file executed a command on the host"
contains "$ATTACK_OUTPUT" "case.yaml is a symbolic link"
# an approval directory inside the evidence is not trusted
S_INSIDE="$WORK/s-inside"; scenario_from_kind "$S_INSIDE" verified-independent
mkdir -p "$S_INSIDE/evidence/approvals"; cp "$(scenario_approvals "$S_INSIDE")"/*.json "$S_INSIDE/evidence/approvals/"
INSIDE_OUT="$(ATD_ALLOWED_SIGNERS_FILE="$KEYS/allowed" node "$WORK/eval/discovery/repair-request.mjs" --results="$S_INSIDE/results.json" --evidence-root="$S_INSIDE/evidence" --ledger-dir="$WORK/ledger-inside" --state-dir="$EVAL_STATE_DIR" --approval-dir="$S_INSIDE/evidence/approvals")"
jq -e '(.independentVerified|length)==0 and (.requests|length)==0 and ([.advisories[]?.reason]|any(contains("not trusted")))' <<<"$INSIDE_OUT" >/dev/null || fail "an approvalDir inside the evidence must not be trusted: $INSIDE_OUT"
# no approvalDir at all keeps the finding an advisory
NOAPP_OUT="$(ATD_ALLOWED_SIGNERS_FILE="$KEYS/allowed" node "$WORK/eval/discovery/repair-request.mjs" --results="$S_INSIDE/results.json" --evidence-root="$S_INSIDE/evidence" --ledger-dir="$WORK/ledger-noapp" --state-dir="$EVAL_STATE_DIR")"
jq -e '(.independentVerified|length)==0 and (.requests|length)==0 and ([.advisories[]?.reason]|any(contains("no trusted approvalDir")))' <<<"$NOAPP_OUT" >/dev/null || fail "no trusted approvalDir must leave an advisory: $NOAPP_OUT"

echo "PASS discovery_jev_gate"
