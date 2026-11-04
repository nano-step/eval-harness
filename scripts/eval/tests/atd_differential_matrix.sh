#!/usr/bin/env bash
# atd_differential_matrix: every base/candidate outcome produced by REAL sandbox executions, the
# structured-evidence interpretation for node:test and Vitest, environment equality, dependency
# immutability and tamper evidence. Live parts need Docker + the pinned image (SKIP otherwise).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/atd/fixture.sh"
source "$ATD_FX_EVAL_DIR/lib/atd_attest.sh"

TMP="$(mktemp -d -t atd-matrix.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
export EVAL_STATE_DIR="$TMP/state"
unset ATD_TRUST ATD_SIGNING_KEY_FILE ATD_ALLOWED_SIGNERS_FILE EVAL_ATD_POLICY DOCKER_HOST || true
NODE="$(atd_resolve_node)"

echo "== structured reporter evidence (node:test + Vitest) is interpreted conservatively =="
"$NODE" "$SCRIPT_DIR/atd/outcome-derivation.mjs" && atd_fx_pass "outcome derivation suite" || atd_fx_fail "outcome derivation suite"


if ! atd_fx_sandbox_available; then
  echo "SKIP(live): Docker daemon or pinned image unavailable; the real differential matrix needs both"
  atd_fx_finish
fi

atd_fx_new_repo "$TMP/repo"
n=0
# run_case <name> <base> <candidate> <test-body> [extra-config-json] [framework] [file]
run_case() {
  local name="$1" base="$2" cand="$3" body="$4" extra="${5:-}" framework="${6:-node:test}" file="${7:-clamp.test.mjs}"
  n=$((n+1)); WD="$TMP/case$n/workdir"; mkdir -p "$WD"
  ATD_FX_BASE="$base" ATD_FX_CANDIDATE="$cand" atd_fx_case "$WD" "$name" "$body" "$framework" "$file"
  atd_fx_spawn "$WD" "$(atd_fx_config "$base" "$cand" "$extra")"
}
expect_matrix() { # <description> <matrix> <base-outcome> <cand-outcome> <environmentEqual>
  if [[ "$ATD_FX_RC" != "0" ]]; then atd_fx_fail "$1: spawn exit $ATD_FX_RC: $(tail -4 "$ATD_FX_ERR")"; return; fi
  local d="$WD/atd-out/differential.json" got
  got="$(jq -r '[(.matrix),(.environmentEqual|tostring)]|join(",")' "$d")"
  if [[ "$got" != "$2,$5" ]]; then atd_fx_fail "$1: matrix/env '$got' != '$2,$5' ($(jq -c '.environmentMismatch' "$d"))"; return; fi
  if [[ "$(jq -r .outcome "$WD/atd-out/base.json")/$(jq -r .outcome "$WD/atd-out/candidate.json")" != "$3/$4" ]]; then atd_fx_fail "$1: outcomes differ"; return; fi
  atd_fx_verify_json "$WD/atd-out"
  if [[ "$ATD_FX_VRC" != "0" ]]; then atd_fx_fail "$1: evidence does not verify: $ATD_FX_VJSON"; return; fi
  if [[ ! -s "$ATD_FX_TRANSCRIPT" ]]; then atd_fx_fail "$1: transcript empty on success"; return; fi
  atd_fx_pass "$1"
}

echo "== differential matrix from real executions =="
run_case pp "$SHA_GOOD" "$SHA_COSMETIC" "$ATD_FX_TEST_UPPER_BOUNDARY"
expect_matrix "PASS->PASS (cosmetic change)" "PASS->PASS" pass pass true
PP_WD="$WD"
run_case pf "$SHA_GOOD" "$SHA_REGRESS" "$ATD_FX_TEST_UPPER_BOUNDARY"
expect_matrix "PASS->FAIL (boundary regression)" "PASS->FAIL" pass fail true
PF_WD="$WD"
jq -e '.counts.assertionFailures==1 and .counts.executed==2' "$WD/atd-out/candidate.json" >/dev/null && atd_fx_pass "candidate record carries structured counts (1 assertion failure of 2 executed)" || atd_fx_fail "counts: $(jq -c .counts "$WD/atd-out/candidate.json")"
BOTH_TEST='import test from "node:test";
import assert from "node:assert/strict";
import { clamp } from "../src/clamp.mjs";
test("upper boundary", () => { assert.equal(clamp(10, 0, 10), 10); });
test("lower boundary", () => { assert.equal(clamp(0, 0, 10), 0); });
'
run_case ff "$SHA_REGRESS" "$SHA_REGRESS2" "$BOTH_TEST"
expect_matrix "FAIL->FAIL (existing failure on both sides)" "FAIL->FAIL" fail fail true
run_case fp "$SHA_REGRESS" "$SHA_GOOD" "$ATD_FX_TEST_UPPER_BOUNDARY"
expect_matrix "FAIL->PASS (the change fixed it)" "FAIL->PASS" fail pass true
SYNTAX_TEST='import test from "node:test";
test("broken", ( => {
'
run_case err "$SHA_GOOD" "$SHA_COSMETIC" "$SYNTAX_TEST"
expect_matrix "ERROR (test file does not compile on either side)" "ERROR" error error true
jq -e '.errorClass=="compile"' "$WD/atd-out/base.json" "$WD/atd-out/candidate.json" >/dev/null && atd_fx_pass "compile errors are classified errorClass=compile, not fail" || atd_fx_fail "errorClass: $(jq -c .errorClass "$WD/atd-out/base.json")"
NEWMOD_TEST='import test from "node:test";
import assert from "node:assert/strict";
import { answer } from "../src/new.mjs";
test("uses the new module", () => { assert.equal(answer, 42); });
'
run_case oneside "$SHA_GOOD" "$SHA_NEWMOD" "$NEWMOD_TEST"
expect_matrix "ERROR when only the base side cannot load the test (never read as FAIL->PASS)" "ERROR" error pass true
NESTED_NODE_TEST='import test from "node:test";
import assert from "node:assert/strict";
import { clamp } from "../src/clamp.mjs";
test("upper boundary is inclusive", () => { assert.equal(clamp(10, 0, 10), 10); });
'
echo "== input root (testsDir) is separate from revision placement (testsRel) =="
run_case nested "$SHA_GOOD" "$SHA_REGRESS" "$NESTED_NODE_TEST" '{"testsRel":"."}' node:test test/nested.test.mjs
expect_matrix "nested test/<name> from input root tests/, placement '.': PASS->FAIL" "PASS->FAIL" pass fail true
jq -e '(.argv|index("--test-path=/work/test/nested.test.mjs")!=null) and (.argv|index("--test-rel=test/nested.test.mjs")!=null)' "$WD/atd-out/candidate.json" >/dev/null && atd_fx_pass "argv carries the normalized revision path (no /work/./)" || atd_fx_fail "argv: $(jq -c .argv "$WD/atd-out/candidate.json")"
run_case nesteddefault "$SHA_GOOD" "$SHA_REGRESS" "$NESTED_NODE_TEST" '{"testsRel":null}' node:test test/nested.test.mjs
if [[ "$ATD_FX_RC" == "13" ]] && grep -q "safe relative path" "$ATD_FX_ERR"; then atd_fx_pass "testsRel must be a string (null is refused, no silent default)"; else atd_fx_fail "null testsRel: rc=$ATD_FX_RC $(tail -2 "$ATD_FX_ERR")"; fi
n=$((n+1)); WD="$TMP/case$n/workdir"; mkdir -p "$WD"; ATD_FX_BASE="$SHA_GOOD" ATD_FX_CANDIDATE="$SHA_REGRESS" atd_fx_case "$WD" nesteddef "$NESTED_NODE_TEST" node:test test/nested.test.mjs
atd_fx_spawn "$WD" "$(jq -c 'del(.testsRel)' <<<"$(atd_fx_config "$SHA_GOOD" "$SHA_REGRESS")")"
[[ "$ATD_FX_RC" == "0" && "$(jq -r .matrix "$WD/atd-out/differential.json")" == "PASS->FAIL" ]] && atd_fx_pass "omitted testsRel defaults to the revision root '.'" || atd_fx_fail "default placement: rc=$ATD_FX_RC $(tail -2 "$ATD_FX_ERR")"
run_case misplaced "$SHA_GOOD" "$SHA_REGRESS" "$NESTED_NODE_TEST" '{"testsRel":"tests"}' node:test test/nested.test.mjs
expect_matrix "same nested bytes placed under tests/ (the old behaviour) cannot resolve ../src: ERROR" "ERROR" error error true
jq -e '.errorClass=="compile"' "$WD/atd-out/base.json" >/dev/null && atd_fx_pass "misplacement surfaces as errorClass=compile, never as a finding" || atd_fx_fail "errorClass: $(jq -c .errorClass "$WD/atd-out/base.json")"
THROW_TEST='import test from "node:test";
import { clamp } from "../src/clamp.mjs";
test("throws a non-assertion error", () => { null.boom; clamp(1, 0, 2); });
'
run_case rt "$SHA_GOOD" "$SHA_COSMETIC" "$THROW_TEST"
expect_matrix "runtime exception that is not an assertion is ERROR, never a finding" "ERROR" error error true
jq -e '.errorClass=="runtime_error"' "$WD/atd-out/base.json" >/dev/null && atd_fx_pass "errorClass=runtime_error" || atd_fx_fail "errorClass: $(jq -c .errorClass "$WD/atd-out/base.json")"

echo "== environment equality =="
run_case lock "$SHA_LOCK_A" "$SHA_LOCK_B" "$ATD_FX_TEST_UPPER_BOUNDARY"
expect_matrix "revisions with different lockfiles => environmentEqual=false (forces INCONCLUSIVE downstream)" "PASS->PASS" pass pass false
jq -e '.environmentMismatch | index("revision.lockfileSha256") != null' "$WD/atd-out/differential.json" >/dev/null && atd_fx_pass "mismatch names revision.lockfileSha256" || atd_fx_fail "mismatch list: $(jq -c .environmentMismatch "$WD/atd-out/differential.json")"
[[ "$(jq -r .image.digest "$WD/atd-out/base.json")" == "$(jq -r .image.digest "$ATD_FX_POLICY")" && "$(jq -r .profile.id "$WD/atd-out/base.json")" == "atd-sandbox/v1" && "$(jq -r '.sandboxProfileSha256|length' "$WD/atd-out/base.json")" == "64" ]] && atd_fx_pass "records bind pinned image digest and sandbox profile hash" || atd_fx_fail "image/profile binding"
[[ "$(jq -r .sandboxProfileSha256 "$WD/atd-out/base.json")" == "$(jq -r .sandboxProfileSha256 "$WD/atd-out/candidate.json")" ]] && atd_fx_pass "both sides ran under the identical sandbox profile" || atd_fx_fail "profile hashes differ between sides"

echo "== same immutable dependency snapshot on both sides =="
SNAP="$TMP/deps"
mkdir -p "$SNAP/node_modules/tinylib"
printf '{"name":"tinylib","version":"1.0.0","type":"module","exports":"./index.mjs"}\n' > "$SNAP/node_modules/tinylib/package.json"
printf 'export const value = 3;\n' > "$SNAP/node_modules/tinylib/index.mjs"
printf '{"lockfileVersion":3,"packages":{"":{"name":"snap"}}}\n' > "$SNAP/package-lock.json"
DEPS_TEST='import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import { value } from "tinylib";
test("dependency resolves from the snapshot", () => { assert.equal(value, 3); });
test("dependency snapshot is read-only", () => {
  let code = "allowed";
  try { fs.writeFileSync("/work/node_modules/tinylib/index.mjs", "export const value = 4;"); } catch (e) { code = e.code; }
  assert.equal(code, "EROFS");
});
'
run_case deps "$SHA_GOOD" "$SHA_COSMETIC" "$DEPS_TEST" "{\"dependencies\":\"$SNAP\"}"
expect_matrix "both sides resolve imports from the one snapshot" "PASS->PASS" pass pass true
bd="$(jq -r '[.depsSnapshotSha256,.lockfileSha256]|join(",")' "$WD/atd-out/base.json")"; cd_="$(jq -r '[.depsSnapshotSha256,.lockfileSha256]|join(",")' "$WD/atd-out/candidate.json")"
[[ "$bd" == "$cd_" && "$bd" != "," && "$bd" != "null,null" && "$bd" != null* ]] && atd_fx_pass "identical non-null depsSnapshotSha256/lockfileSha256 on both records" || atd_fx_fail "deps hashes: $bd vs $cd_"
[[ "$(cat "$SNAP/node_modules/tinylib/index.mjs")" == "export const value = 3;" ]] && atd_fx_pass "snapshot on the host is unmodified after the run" || atd_fx_fail "snapshot was modified by the sandbox"
run_case depslock "$SHA_LOCK_A" "$SHA_LOCK_A" "$DEPS_TEST" "{\"dependencies\":\"$SNAP\"}"
expect_matrix "revision lockfile that differs from the snapshot lockfile is inconclusive" "PASS->PASS" pass pass false
jq -e '.environmentMismatch | map(select(test("revisionLockfileDiffersFromSnapshot"))) | length == 2' "$WD/atd-out/differential.json" >/dev/null && atd_fx_pass "mismatch reported for both sides" || atd_fx_fail "mismatch: $(jq -c .environmentMismatch "$WD/atd-out/differential.json")"
run_case nodeps "$SHA_GOOD" "$SHA_COSMETIC" "$DEPS_TEST"
if [[ "$ATD_FX_RC" == "0" ]] && [[ "$(jq -r .matrix "$WD/atd-out/differential.json")" == "ERROR" ]]; then atd_fx_pass "importing an uninstalled package without a snapshot is ERROR (no network install)"; else atd_fx_fail "missing dependency not an error: rc=$ATD_FX_RC"; fi

echo "== evidence integrity on a real PASS->FAIL run =="
OUT="$PF_WD/atd-out"
atd_fx_verify_json "$OUT"
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
[[ "$(jq -r .candidateManifestSha256 <<<"$ATD_FX_VJSON")" == "$(sha "$PF_WD/candidate.json")" ]] && atd_fx_pass "attestation binds the candidate manifest bytes" || atd_fx_fail "candidateManifestSha256 mismatch"
[[ "$(jq -r .specSha256 <<<"$ATD_FX_VJSON")" == "$(sha "$PF_WD/SPEC.md")" ]] && atd_fx_pass "attestation binds the spec bytes" || atd_fx_fail "specSha256 mismatch"
[[ "$(jq -r .testSha256 <<<"$ATD_FX_VJSON")" == "$(sha "$PF_WD/tests/clamp.test.mjs")" ]] && atd_fx_pass "attestation binds the test bytes" || atd_fx_fail "testSha256 mismatch"
[[ "$(jq -r '.ehRunId+"/"+.caseId' <<<"$ATD_FX_VJSON")" == "run-test/case-test" ]] && atd_fx_pass "attestation is bound to EVAL_RUN_ID/EVAL_CASE_ID" || atd_fx_fail "run/case binding: $ATD_FX_VJSON"
echo '// modified after execution' >> "$PF_WD/tests/clamp.test.mjs"
[[ "$(jq -r .testSha256 <<<"$ATD_FX_VJSON")" != "$(sha "$PF_WD/tests/clamp.test.mjs")" ]] && atd_fx_pass "a modified test file no longer matches the signed testSha256" || atd_fx_fail "modified test undetected"
echo 'forged quote' >> "$PF_WD/SPEC.md"
[[ "$(jq -r .specSha256 <<<"$ATD_FX_VJSON")" != "$(sha "$PF_WD/SPEC.md")" ]] && atd_fx_pass "a modified spec no longer matches the signed specSha256" || atd_fx_fail "modified spec undetected"
cp "$OUT/candidate.json" "$TMP/cand.bak"
jq -c '.outcome="pass"' "$OUT/candidate.json" > "$TMP/x" && cp "$TMP/x" "$OUT/candidate.json"
atd_fx_verify_json "$OUT"; [[ "$ATD_FX_VRC" == "1" ]] && atd_fx_pass "flipping the candidate outcome invalidates the evidence" || atd_fx_fail "flipped outcome verified"
cp "$TMP/cand.bak" "$OUT/candidate.json"
printf '{"schema":"atd.node-test-report/v1","tests":[]}' > "$OUT/artifacts/candidate.node-test.json"
atd_fx_verify_json "$OUT"; [[ "$ATD_FX_VRC" == "1" ]] && atd_fx_pass "a swapped reporter artifact invalidates the evidence" || atd_fx_fail "swapped reporter verified"

echo "== fresh execution identity and no stale evidence on respawn =="
first_ids="$(jq -r '.executionIds|join(",")' <<<"$(bash "$ATD_FX_EVAL_DIR/lib/atd_attest.sh" verify "$PP_WD/atd-out")")"
mkdir -p "$PP_WD/atd-out"; echo '{"planted":true}' > "$PP_WD/atd-out/planted.json"
echo '{"event":"stale"}' > "$ATD_FX_TRANSCRIPT"
ATD_FX_BASE="$SHA_GOOD" ATD_FX_CANDIDATE="$SHA_COSMETIC" atd_fx_spawn "$PP_WD" "$(atd_fx_config "$SHA_GOOD" "$SHA_COSMETIC")"
atd_fx_verify_json "$PP_WD/atd-out"
second_ids="$(jq -r '.executionIds|join(",")' <<<"$ATD_FX_VJSON")"
[[ "$ATD_FX_RC" == "0" && "$ATD_FX_VRC" == "0" && "$first_ids" != "$second_ids" && ! -e "$PP_WD/atd-out/planted.json" ]] \
  && atd_fx_pass "respawn yields fresh executionIds and discards planted/stale evidence" || atd_fx_fail "respawn: rc=$ATD_FX_RC ids '$first_ids' vs '$second_ids'"
[[ "$(grep -c stale "$ATD_FX_TRANSCRIPT" || true)" == "0" ]] && atd_fx_pass "stale transcript replaced" || atd_fx_fail "stale transcript kept"

if [[ -n "${ATD_TEST_VITEST_DEPS:-}" && -f "${ATD_TEST_VITEST_DEPS}/node_modules/vitest/vitest.mjs" ]]; then
  echo "== live Vitest (dependency snapshot from ATD_TEST_VITEST_DEPS) =="
  VT_TEST='import { test, expect } from "vitest";
import { clamp } from "../src/clamp.mjs";
test("upper boundary is inclusive", () => { expect(clamp(10, 0, 10)).toBe(10); });
'
  run_case vitest "$SHA_GOOD" "$SHA_REGRESS" "$VT_TEST" "{\"dependencies\":\"$ATD_TEST_VITEST_DEPS\",\"timeoutSeconds\":120}" vitest clamp.test.ts
  expect_matrix "Vitest PASS->FAIL from the structured JSON reporter" "PASS->FAIL" pass fail true
  # Generated contract: candidate.testFile is REVISION-relative (test/<name>) and lives under the host input root tests/.
  # Placement '.' puts it at /work/test/<name>, so `../src` resolves to the revision's src. The same bytes placed
  # under tests/ (the pre-fix behaviour) resolve ../src to /work/tests/src, which does not exist.
  VT_NESTED='import { test, expect } from "vitest";
import { clamp } from "../src/clamp.mjs";
test("upper boundary is inclusive", () => { expect(clamp(10, 0, 10)).toBe(10); });
'
  run_case vtnested "$SHA_GOOD" "$SHA_REGRESS" "$VT_NESTED" "{\"dependencies\":\"$ATD_TEST_VITEST_DEPS\",\"testsRel\":\".\",\"timeoutSeconds\":120}" vitest test/flush-move.test.ts
  expect_matrix "Vitest nested test/<name> at placement '.' imports ../src: PASS->FAIL" "PASS->FAIL" pass fail true
  jq -e '(.argv|index("--test-rel=test/flush-move.test.ts")!=null) and (.argv|index("--test-path=/work/test/flush-move.test.ts")!=null)' "$WD/atd-out/base.json" >/dev/null && atd_fx_pass "argv carries the normalized revision path (no /work/./)" || atd_fx_fail "argv: $(jq -c .argv "$WD/atd-out/base.json")"
  run_case vtmisplaced "$SHA_GOOD" "$SHA_REGRESS" "$VT_NESTED" "{\"dependencies\":\"$ATD_TEST_VITEST_DEPS\",\"testsRel\":\"tests\",\"timeoutSeconds\":120}" vitest test/flush-move.test.ts
  expect_matrix "same nested bytes placed under tests/ cannot resolve ../src: ERROR (placement is explicit)" "ERROR" error error true
  run_case vtflat "$SHA_GOOD" "$SHA_REGRESS" "$VT_TEST" "{\"dependencies\":\"$ATD_TEST_VITEST_DEPS\",\"testsRel\":\"tests\",\"timeoutSeconds\":120}" vitest clamp.test.ts
  expect_matrix "flat Vitest test with placement tests still works: PASS->FAIL" "PASS->FAIL" pass fail true
else
  echo "SKIP(vitest live): set ATD_TEST_VITEST_DEPS to a dependency snapshot containing vitest to exercise the Vitest path end to end"
fi

atd_fx_finish
