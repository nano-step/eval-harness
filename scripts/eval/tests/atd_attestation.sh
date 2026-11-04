#!/usr/bin/env bash
# atd_attestation: signed evidence can not be forged. Genuine signed atd-out directories are produced by
# the real signer and then tampered with the way a modified reporter/manifest/test/spec or a hostile
# worker would; atd_verify (the grader-facing API) must classify absent signatures as unavailable (3) and
# every integrity or trust violation as invalid (1). No Docker needed.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/atd/fixture.sh"
source "$ATD_FX_EVAL_DIR/lib/atd_attest.sh"

TMP="$(mktemp -d -t atd-attest.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
export EVAL_STATE_DIR="$TMP/state"
unset ATD_TRUST ATD_SIGNING_KEY_FILE ATD_ALLOWED_SIGNERS_FILE ATD_NODE || true
NODE="$(atd_resolve_node)"
MAKE="$SCRIPT_DIR/atd/make-evidence.mjs"
ATTEST="$ATD_FX_EVAL_DIR/discovery/attest.mjs"

fresh() { local d="$TMP/$1"; rm -rf "$d"; "$NODE" "$MAKE" "$d" >/dev/null; printf '%s' "$d"; }
expect_status() { # <description> <out-dir> <expected-exit> <expected-status>
  atd_fx_verify_json "$2"
  if [[ "$ATD_FX_VRC" == "$3" && "$(jq -r .status <<<"$ATD_FX_VJSON")" == "$4" ]]; then atd_fx_pass "$1"; else atd_fx_fail "$1 (exit=$ATD_FX_VRC json=$ATD_FX_VJSON)"; fi
}

echo "== policy: default trust never authorizes blocking =="
jq -e '.trust.default == "local-same-user" and ((.trust.blockingEligible // []) | index("local-same-user") == null)' "$ATD_FX_POLICY" >/dev/null \
  && atd_fx_pass "root policy default is local-same-user and not blocking-eligible" || atd_fx_fail "root policy trust defaults"

echo "== genuine evidence verifies =="
D="$(fresh genuine)"
expect_status "genuine evidence is valid" "$D" 0 valid
jq -e '.trust=="local-same-user" and (.executionIds|length)==2 and .matrix=="PASS->FAIL" and .environmentEqual==true and (.testSha256|length)==64 and (.candidateManifestSha256|length)==64 and (.specSha256|length)==64 and .candidateId=="cand-1"' <<<"$ATD_FX_VJSON" >/dev/null \
  && atd_fx_pass "valid result carries trust, executionIds, matrix and the bound manifest/test/spec hashes" || atd_fx_fail "valid JSON shape: $ATD_FX_VJSON"
rm -rf "$TMP/copy"; cp -R "$D" "$TMP/copy"
expect_status "verification is relocatable (key independent of out-dir)" "$TMP/copy" 0 valid
if atd_blocking_eligible "$D"; then atd_fx_fail "local-same-user evidence must not be blocking-eligible"; else atd_fx_pass "local-same-user evidence is not blocking-eligible"; fi

echo "== absent evidence is UNAVAILABLE (exit 3), distinct from invalid =="
expect_status "out-dir missing" "$TMP/does-not-exist" 3 unavailable
D="$(fresh nosig)"; rm "$D/attestation.json.sig"
expect_status "signature absent" "$D" 3 unavailable
D="$(fresh noatt)"; rm "$D/attestation.json"
expect_status "attestation absent" "$D" 3 unavailable

echo "== forged/modified evidence is INVALID (exit 1) =="
D="$(fresh t-record)"; jq -c '.outcome="pass" | .exitCode=0' "$D/candidate.json" > "$D/x" && mv "$D/x" "$D/candidate.json"
expect_status "modified execution record (outcome flipped to pass)" "$D" 1 invalid
D="$(fresh t-diff)"; jq -c '.matrix="PASS->PASS"' "$D/differential.json" > "$D/x" && mv "$D/x" "$D/differential.json"
expect_status "modified differential matrix" "$D" 1 invalid
D="$(fresh t-reporter)"; printf '{"side":"candidate","outcome":"pass"}\n' > "$D/artifacts/candidate.node-test.json"
expect_status "modified reporter artifact" "$D" 1 invalid
D="$(fresh t-att)"; jq -c '.candidateManifestSha256="'"$(printf '%064d' 1)"'"' "$D/attestation.json" > "$D/x" && mv "$D/x" "$D/attestation.json"
expect_status "modified attestation (manifest hash swapped, signature stale)" "$D" 1 invalid
D="$(fresh t-extra)"; echo '{}' > "$D/artifacts/extra.json"
expect_status "unattested file injected under artifacts/" "$D" 1 invalid
D="$(fresh t-link)"; rm "$D/artifacts/base.node-test.json"; ln -s /etc/hosts "$D/artifacts/base.node-test.json"
expect_status "symlink replaces an attested artifact" "$D" 1 invalid
D="$(fresh t-dir-link)"; mv "$D" "$TMP/real-evidence"; ln -s "$TMP/real-evidence" "$D"
expect_status "out-dir itself is a symlink" "$D" 1 invalid
D="$(fresh t-missing-art)"; rm "$D/artifacts/candidate.node-test.json"
expect_status "attested artifact deleted" "$D" 1 invalid
D="$TMP/t-escape"; rm -rf "$D"; "$NODE" "$MAKE" "$D" --malformed-artifact-path >/dev/null
expect_status "validly signed attestation listing an escaping artifact path" "$D" 1 invalid

echo "== signer identity: rogue keys and self-upgraded trust are rejected =="
D="$(fresh t-rogue)"
ssh-keygen -q -t ed25519 -N '' -f "$TMP/rogue" >/dev/null
rm -f "$D/attestation.json.sig"
ssh-keygen -q -Y sign -f "$TMP/rogue" -n atd-execution@v1 "$D/attestation.json"
expect_status "signature by an unknown (rogue) key" "$D" 1 invalid
D="$(fresh t-upgrade)"
jq -c '.trust="ci-secret"' "$D/attestation.json" > "$D/x" && mv "$D/x" "$D/attestation.json"
rm -f "$D/attestation.json.sig"
ssh-keygen -q -Y sign -f "$EVAL_STATE_DIR/discovery/keys/runner_ed25519" -n atd-execution@v1 "$D/attestation.json"
expect_status "local key re-signing the attestation as ci-secret (no external signers configured)" "$D" 1 invalid
ATD_ALLOWED_SIGNERS_FILE="$EVAL_STATE_DIR/discovery/keys/allowed_signers" atd_fx_verify_json "$D"
[[ "$ATD_FX_VRC" == "1" ]] && atd_fx_pass "local key cannot be passed off as an external signer for ci-secret" || atd_fx_fail "self-upgrade accepted with local allowed_signers: $ATD_FX_VJSON"

echo "== external keys: ci-secret evidence is valid only against the external allowed signers =="
ssh-keygen -q -t ed25519 -N '' -f "$TMP/ci_key" >/dev/null
pub="$(cut -d' ' -f1,2 "$TMP/ci_key.pub")"
printf 'atd-runner-ci-secret namespaces="atd-execution@v1" %s\n' "$pub" > "$TMP/ci_allowed"
chmod 600 "$TMP/ci_key"
D="$TMP/ci-evidence"; rm -rf "$D"
ATD_TRUST=ci-secret ATD_SIGNING_KEY_FILE="$TMP/ci_key" ATD_ALLOWED_SIGNERS_FILE="$TMP/ci_allowed" "$NODE" "$MAKE" "$D" >/dev/null
ATD_ALLOWED_SIGNERS_FILE="$TMP/ci_allowed" atd_fx_verify_json "$D"
[[ "$ATD_FX_VRC" == "0" && "$(jq -r .trust <<<"$ATD_FX_VJSON")" == "ci-secret" ]] && atd_fx_pass "externally signed ci-secret evidence verifies with its allowed signers" || atd_fx_fail "ci-secret verify: $ATD_FX_VRC $ATD_FX_VJSON"
if ATD_ALLOWED_SIGNERS_FILE="$TMP/ci_allowed" atd_blocking_eligible "$D"; then atd_fx_pass "ci-secret evidence is blocking-eligible"; else atd_fx_fail "ci-secret evidence should be blocking-eligible"; fi
atd_fx_verify_json "$D"
[[ "$ATD_FX_VRC" == "1" ]] && atd_fx_pass "ci-secret evidence is invalid without the external allowed signers" || atd_fx_fail "ci-secret verified without external signers: $ATD_FX_VJSON"
if ATD_TRUST=ci-secret "$NODE" "$MAKE" "$TMP/no-key" >/dev/null 2>&1; then atd_fx_fail "ATD_TRUST=ci-secret without an external key must refuse to sign"; else atd_fx_pass "ATD_TRUST=ci-secret without an external key refuses to sign"; fi
chmod 644 "$TMP/ci_key"
if ATD_TRUST=ci-secret ATD_SIGNING_KEY_FILE="$TMP/ci_key" ATD_ALLOWED_SIGNERS_FILE="$TMP/ci_allowed" "$NODE" "$MAKE" "$TMP/open-key" >/dev/null 2>&1; then atd_fx_fail "group/world readable signing key must be refused"; else atd_fx_pass "group/world readable signing key is refused"; fi
chmod 600 "$TMP/ci_key"
if ATD_SIGNING_KEY_FILE="$TMP/ci_key" ATD_ALLOWED_SIGNERS_FILE="$TMP/ci_allowed" ATD_TRUST=separate-user "$NODE" "$MAKE" "$TMP/wrong-principal" >/dev/null 2>&1; then
  atd_fx_fail "signing as separate-user with a key only authorized for ci-secret must fail the signer self-check"
else atd_fx_pass "key authorized for one trust level cannot sign another"; fi

echo "== verifier unavailable fails closed =="
if ATD_NODE=/nonexistent/node PATH=/usr/bin:/bin bash -c "source '$ATD_FX_EVAL_DIR/lib/atd_attest.sh'; atd_verify '$TMP/genuine' >/dev/null"; then
  atd_fx_fail "missing node must not verify"
else atd_fx_pass "no usable node => verification fails (exit non-zero), never valid"; fi

atd_fx_finish
