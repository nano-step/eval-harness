#!/usr/bin/env bash
# atd_sandbox_failclosed: the atd-sandbox runner never executes untrusted tests outside the confinement
# profile and never leaves evidence behind when it cannot. Every violation below must end with exit 13,
# an EMPTY transcript and NO atd-out (so run.sh records ERROR instead of grading stale files).
# The first half needs no Docker image; the live half (SKIP without daemon+pinned image) proves the
# effective confinement from inside the container and the host-side deadline/cleanup.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/atd/fixture.sh"
source "$ATD_FX_EVAL_DIR/lib/atd_attest.sh"

TMP="$(mktemp -d -t atd-failclosed.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
export EVAL_STATE_DIR="$TMP/state"
unset ATD_TRUST ATD_SIGNING_KEY_FILE ATD_ALLOWED_SIGNERS_FILE EVAL_ATD_POLICY DOCKER_HOST || true
NODE="$(atd_resolve_node)"
atd_fx_new_repo "$TMP/repo"
export ATD_FX_BASE="$SHA_GOOD" ATD_FX_CANDIDATE="$SHA_REGRESS"

n=0
new_wd() { n=$((n+1)); WD="$TMP/case$n/workdir"; mkdir -p "$WD"; atd_fx_case "$WD" "case-$n" "$ATD_FX_TEST_UPPER_BOUNDARY"; }
plant_stale() { mkdir -p "$WD/atd-out"; echo '{"stale":true}' > "$WD/atd-out/differential.json"; echo '{"event":"stale"}' > "$TMP/case$n/transcript.jsonl"; }

# expect_closed <description> <config-json> [stderr-substring]
expect_closed() {
  local desc="$1" cfg="$2" want="${3:-}"
  plant_stale
  atd_fx_spawn "$WD" "$cfg"
  if [[ "$ATD_FX_RC" != "13" ]]; then atd_fx_fail "$desc: exit $ATD_FX_RC (expected 13) $(tail -3 "$ATD_FX_ERR")"; return; fi
  if [[ -s "$ATD_FX_TRANSCRIPT" ]]; then atd_fx_fail "$desc: transcript not empty"; return; fi
  if [[ -e "$WD/atd-out" ]]; then atd_fx_fail "$desc: stale/partial atd-out left behind"; return; fi
  if ls "$WD"/.atd-out.stage-* >/dev/null 2>&1; then atd_fx_fail "$desc: staging directory left behind"; return; fi
  if [[ -n "$want" ]] && ! grep -q -- "$want" "$ATD_FX_ERR"; then atd_fx_fail "$desc: stderr lacks '$want': $(tail -2 "$ATD_FX_ERR")"; return; fi
  atd_fx_pass "$desc"
}

echo "== input validation fails closed (no Docker involved) =="
new_wd; expect_closed "unknown runner_config key (host command smuggling)" "$(atd_fx_config "$SHA_GOOD" "$SHA_REGRESS" '{"hostCommand":"touch /tmp/pwned"}')" "unknown runner_config key"
new_wd; expect_closed "non-pinned image reference" "$(atd_fx_config "$SHA_GOOD" "$SHA_REGRESS" '{"image":"node:22-bookworm-slim"}')" "not a digest-pinned image"
new_wd; expect_closed "pinned-looking image outside the trusted policy" "$(atd_fx_config "$SHA_GOOD" "$SHA_REGRESS" "{\"image\":\"evil@sha256:$(printf '%064d' 1)\"}")" "allowed by the trusted policy"
new_wd; expect_closed "branch name instead of full commit SHA" "$(atd_fx_config "main" "$SHA_REGRESS")" "40-hex"
new_wd; expect_closed "commit missing from the repository" "$(atd_fx_config "$(printf '%040d' 0)" "$SHA_REGRESS")" "does not exist"
new_wd; expect_closed "timeout above the policy bound" "$(atd_fx_config "$SHA_GOOD" "$SHA_REGRESS" '{"timeoutSeconds":100000}')" "timeoutSeconds"
new_wd; expect_closed "relative repository path" "$(atd_fx_config "$SHA_GOOD" "$SHA_REGRESS" '{"repository":"relative/repo"}')" "absolute"
new_wd; expect_closed "testsDir traversal" "$(atd_fx_config "$SHA_GOOD" "$SHA_REGRESS" '{"testsDir":"../escape"}')" "safe relative path"
new_wd; expect_closed "testsRel traversal" "$(atd_fx_config "$SHA_GOOD" "$SHA_REGRESS" '{"testsRel":"../escape"}')" "safe relative path"
new_wd; expect_closed "testsRel absolute path" "$(atd_fx_config "$SHA_GOOD" "$SHA_REGRESS" '{"testsRel":"/etc"}')" "safe relative path"
new_wd; expect_closed "testsRel dot segment other than the exact root selector" "$(atd_fx_config "$SHA_GOOD" "$SHA_REGRESS" '{"testsRel":"./tests"}')" "safe relative path"
new_wd; expect_closed "testsDir '.' (not an input root selector)" "$(atd_fx_config "$SHA_GOOD" "$SHA_REGRESS" '{"testsDir":"."}')" "safe relative path"
new_wd; expect_closed "testsRel under node_modules" "$(atd_fx_config "$SHA_GOOD" "$SHA_REGRESS" '{"testsRel":"node_modules/x"}')" "reserved path segment"
new_wd; expect_closed "specFile traversal" "$(atd_fx_config "$SHA_GOOD" "$SHA_REGRESS" '{"specFile":"../../etc/passwd"}')" "safe relative path"
new_wd; expect_closed "dependencies inside the generator-writable workdir" "$(atd_fx_config "$SHA_GOOD" "$SHA_REGRESS" "{\"dependencies\":\"$WD\"}")" "outside the case workdir"
mkdir -p "$TMP/badsnap/real_nm"; echo '{}' > "$TMP/badsnap/package-lock.json"; ln -s "$TMP/badsnap/real_nm" "$TMP/badsnap/node_modules"
new_wd; expect_closed "dependency snapshot whose node_modules is a symlink" "$(atd_fx_config "$SHA_GOOD" "$SHA_REGRESS" "{\"dependencies\":\"$TMP/badsnap\"}")" "plain dir"

new_wd; echo "// tampered after the manifest was hashed" >> "$WD/tests/clamp.test.mjs"
expect_closed "test bytes differ from candidate.testSha256" "$(atd_fx_config "$SHA_GOOD" "$SHA_REGRESS")" "testSha256"
new_wd; ln -s "$HOME" "$WD/tests/leak"
expect_closed "symlink inside the tests directory (host file leak)" "$(atd_fx_config "$SHA_GOOD" "$SHA_REGRESS")" "symlink in tests directory"
new_wd; rm -rf "$WD/tests"; ln -s /etc "$WD/tests"
expect_closed "testsDir itself is a symlink" "$(atd_fx_config "$SHA_GOOD" "$SHA_REGRESS")" "symlink"
new_wd; jq '.trust="trusted"' "$WD/candidate.json" > "$WD/c.tmp" && mv "$WD/c.tmp" "$WD/candidate.json"
expect_closed "candidate manifest claiming trust != untrusted" "$(atd_fx_config "$SHA_GOOD" "$SHA_REGRESS")" "untrusted"
new_wd; jq --arg x "$SHA_REGRESS" '.provenance.baseCommit=$x' "$WD/candidate.json" > "$WD/c.tmp" && mv "$WD/c.tmp" "$WD/candidate.json"
expect_closed "candidate provenance disagrees with runner_config commits" "$(atd_fx_config "$SHA_GOOD" "$SHA_REGRESS")" "provenance.baseCommit"
new_wd; rm "$WD/candidate.json"
expect_closed "candidate manifest missing" "$(atd_fx_config "$SHA_GOOD" "$SHA_REGRESS")" "candidate manifest not found"
new_wd; expect_closed "empty runner_config" "{}" "repository must be an absolute path"

echo "== trust can not be self-upgraded =="
new_wd; ATD_TRUST=ci-secret expect_closed "ATD_TRUST=ci-secret without an external signing key" "$(atd_fx_config "$SHA_GOOD" "$SHA_REGRESS")" "external signing key"
new_wd
cp "$ATD_FX_POLICY" "$TMP/policy-bad-trust.json"; jq '.trust.default="ci-secret"' "$ATD_FX_POLICY" > "$TMP/policy-bad-trust.json"
EVAL_ATD_POLICY="$TMP/policy-bad-trust.json" expect_closed "policy that tries to default to ci-secret is rejected" "$(atd_fx_config "$SHA_GOOD" "$SHA_REGRESS")" "default trust must be local-same-user"
new_wd; jq '.user="0:0"' "$ATD_FX_POLICY" > "$TMP/policy-root.json"
EVAL_ATD_POLICY="$TMP/policy-root.json" expect_closed "policy running the container as root is rejected" "$(atd_fx_config "$SHA_GOOD" "$SHA_REGRESS")" "non-root"
new_wd; jq '.image.ref="node:22"' "$ATD_FX_POLICY" > "$TMP/policy-tag.json"
EVAL_ATD_POLICY="$TMP/policy-tag.json" expect_closed "policy with a tag-only image is rejected" "$(atd_fx_config "$SHA_GOOD" "$SHA_REGRESS")" "digest-pinned"

echo "== missing daemon / missing image: no host fallback =="
new_wd; DOCKER_HOST="unix://$TMP/no-such-docker.sock" expect_closed "unreachable Docker daemon" "$(atd_fx_config "$SHA_GOOD" "$SHA_REGRESS")" "sandbox_preflight"
if DOCKER_HOST="unix://$TMP/no-such-docker.sock" bash -c "source '$ATD_FX_EVAL_DIR/lib/atd_sandbox.sh'; preflight_check_atd_sandbox --quick" >/dev/null 2>&1; then
  atd_fx_fail "preflight_check_atd_sandbox succeeded without a daemon"; else atd_fx_pass "run.sh admission preflight fails without a daemon"; fi
if PATH="$(dirname "$NODE"):/usr/bin:/bin" bash -c "command -v docker" >/dev/null 2>&1; then :; else
  if PATH="$(dirname "$NODE"):/usr/bin:/bin" bash -c "source '$ATD_FX_EVAL_DIR/lib/atd_sandbox.sh'; preflight_check_atd_sandbox --quick" >/dev/null 2>&1; then
    atd_fx_fail "preflight succeeded without a docker CLI"; else atd_fx_pass "run.sh admission preflight fails without a docker CLI"; fi
fi
FAKE_DIGEST="$(printf 'a%.0s' $(seq 64))"
jq --arg r "node@sha256:$FAKE_DIGEST" --arg d "sha256:$FAKE_DIGEST" '.image.ref=$r | .image.digest=$d | .allowedImages=[$r]' "$ATD_FX_POLICY" > "$TMP/policy-missing.json"
new_wd; EVAL_ATD_POLICY="$TMP/policy-missing.json" expect_closed "pinned image absent from the local daemon" "$(atd_fx_config "$SHA_GOOD" "$SHA_REGRESS")" "sandbox_preflight"

echo "== signing material can never sit under a mounted root =="
SNAPK="$TMP/snapk"; mkdir -p "$SNAPK/node_modules"; echo '{}' > "$SNAPK/package-lock.json"
ssh-keygen -q -t ed25519 -N '' -f "$SNAPK/key" >/dev/null; chmod 600 "$SNAPK/key"
printf 'atd-runner-local-same-user namespaces="atd-execution@v1" %s\n' "$(cut -d' ' -f1,2 "$SNAPK/key.pub")" > "$TMP/allowed-k"
new_wd; ATD_SIGNING_KEY_FILE="$SNAPK/key" ATD_ALLOWED_SIGNERS_FILE="$TMP/allowed-k" expect_closed "signing key located inside the mounted dependency snapshot" "$(atd_fx_config "$SHA_GOOD" "$SHA_REGRESS" "{\"dependencies\":\"$SNAPK\"}")" "must live outside"

echo "== run.sh admission (pre-scan) refuses atd-sandbox cases when the sandbox is unavailable =="
if command -v yq >/dev/null 2>&1; then
  export OPENCODE_SKILLS_ROOT="$TMP/skills"
  mkdir -p "$OPENCODE_SKILLS_ROOT/atd-skill/evals/cases"
  cat > "$OPENCODE_SKILLS_ROOT/atd-skill/evals/cases/adm.yaml" <<EOF
id: adm
description: admission
runner: atd-sandbox
prompt: unused
eval_type: capability
compare_to_baseline: false
runner_config: {}
checks:
  - kind: file_exists
    path: never.txt
EOF
  RC=0
  DOCKER_HOST="unix://$TMP/no-such-docker.sock" EVAL_SKIP_AUTH_CHECK=1 bash "$ATD_FX_EVAL_DIR/run.sh" --skill=atd-skill --case=adm --trigger=manual >"$TMP/adm.log" 2>&1 || RC=$?
  [[ "$RC" == "13" ]] && grep -q "runner=atd-sandbox" "$TMP/adm.log" && atd_fx_pass "run.sh exits 13 before any case runs when Docker is unreachable" || atd_fx_fail "admission exit $RC: $(tail -3 "$TMP/adm.log")"
  RC=0
  EVAL_ATD_POLICY="$TMP/policy-missing.json" EVAL_SKIP_AUTH_CHECK=1 bash "$ATD_FX_EVAL_DIR/run.sh" --skill=atd-skill --case=adm --trigger=manual >"$TMP/adm2.log" 2>&1 || RC=$?
  [[ "$RC" == "13" ]] && atd_fx_pass "run.sh exits 13 when the pinned image is absent" || atd_fx_fail "image-missing admission exit $RC: $(tail -3 "$TMP/adm2.log")"
else
  echo "SKIP: yq not installed; run.sh admission assertions skipped"
fi

if ! atd_fx_sandbox_available; then
  echo "SKIP(live): Docker daemon or pinned image unavailable; skipping live confinement assertions"
  atd_fx_finish
fi

echo "== live: effective confinement observed from inside the container =="
SECRET_ENV='sk-ant-api03-LEAK-CANARY'
PROBE_TEST='import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import net from "node:net";
import dns from "node:dns";
import { clamp } from "../src/clamp.mjs";
const attempt = (fn) => { try { fn(); return "allowed"; } catch (e) { return e.code || "denied"; } };
test("no credentials leak into the sandbox", () => {
  for (const k of Object.keys(process.env)) assert.ok(!/KEY|TOKEN|SECRET|PASSWORD|ANTHROPIC|AWS_|OPENAI|GITHUB/i.test(k), `leaked variable ${k}`);
  assert.equal(process.env.ATD_LEAK_CANARY, undefined);
  assert.notEqual(process.getuid(), 0);
});
test("source and rootfs are read-only", () => {
  assert.equal(attempt(() => fs.writeFileSync("/work/src/clamp.mjs", "export const x = 1;")), "EROFS");
  assert.equal(attempt(() => fs.writeFileSync("/work/src/new-file.mjs", "x")), "EROFS");
  assert.equal(attempt(() => fs.writeFileSync("/etc/atd-probe", "x")), "EROFS");
  assert.equal(attempt(() => fs.writeFileSync("/atd/exec.mjs", "x")), "EROFS");
});
test("no host paths or docker socket", () => {
  for (const p of ["/var/run/docker.sock", "/run/docker.sock", "/Users", "/root/.ssh", "/host"]) assert.equal(fs.existsSync(p), false, p);
});
test("network is unreachable", async () => {
  const connected = await new Promise((resolve) => { const s = net.connect({ host: "1.1.1.1", port: 443, timeout: 3000 }); s.on("connect", () => { s.destroy(); resolve(true); }); s.on("error", () => resolve(false)); s.on("timeout", () => { s.destroy(); resolve(false); }); });
  assert.equal(connected, false);
  const resolved = await new Promise((resolve) => dns.lookup("example.com", (err) => resolve(!err)));
  assert.equal(resolved, false);
});
test("scratch space is writable", () => { fs.writeFileSync("/tmp/ok", "x"); assert.equal(clamp(10, 0, 10) >= 9, true); });
'
new_wd; ATD_FX_CANDIDATE="$SHA_COSMETIC" atd_fx_case "$WD" "probe" "$PROBE_TEST"
ANTHROPIC_API_KEY="$SECRET_ENV" AWS_SECRET_ACCESS_KEY="$SECRET_ENV" GITHUB_TOKEN="$SECRET_ENV" ATD_LEAK_CANARY="$SECRET_ENV" \
  atd_fx_spawn "$WD" "$(atd_fx_config "$SHA_GOOD" "$SHA_COSMETIC")"
if [[ "$ATD_FX_RC" == "0" ]]; then
  matrix="$(jq -r .matrix "$WD/atd-out/differential.json")"
  [[ "$matrix" == "PASS->PASS" ]] && atd_fx_pass "all in-container confinement assertions held on both sides (matrix $matrix)" || atd_fx_fail "confinement assertion failed inside the sandbox: matrix=$matrix $(jq -c '.counts' "$WD/atd-out/candidate.json") $(jq -r '.tests[]|select(.status=="fail")|.name+": "+.message' "$WD/atd-out/artifacts/candidate.node-test.json" | head -5)"
  if grep -rq "$SECRET_ENV" "$WD/atd-out" "$TMP/case$n/transcript.jsonl"; then atd_fx_fail "credential canary appears in evidence"; else atd_fx_pass "credential canary absent from every evidence file"; fi
  jq -e '.env | keys == ["ATD_SEED","CI","FC_SEED","LANG","NODE_ENV","TZ"]' "$WD/atd-out/base.json" >/dev/null && atd_fx_pass "record env is exactly the allowlist" || atd_fx_fail "record env not the allowlist"
else atd_fx_fail "probe run exit $ATD_FX_RC: $(tail -3 "$ATD_FX_ERR")"; fi

echo "== live: tests colliding with revision files / unattested overlay are refused =="
OUTSIDE="$TMP/outside-dir"; mkdir -p "$OUTSIDE"
atd_fx_git checkout -q --detach "$SHA_GOOD"; mkdir -p "$ATD_FX_REPO/tests"; ln -s "$OUTSIDE" "$ATD_FX_REPO/tests/foo"
SHA_LINK="$(atd_fx_commit tests-symlink)"
new_wd; ATD_FX_BASE="$SHA_LINK" ATD_FX_CANDIDATE="$SHA_LINK" atd_fx_case "$WD" "overlay-escape" "$ATD_FX_TEST_UPPER_BOUNDARY" node:test foo/escape.test.mjs
expect_closed "test file path crossing a git-controlled symlink in the revision" "$(atd_fx_config "$SHA_LINK" "$SHA_LINK")" "collides with a symlink"
[[ -z "$(ls -A "$OUTSIDE")" ]] && atd_fx_pass "nothing was written outside the export through the symlink" || atd_fx_fail "host path written through revision symlink: $(ls -A "$OUTSIDE")"
jq '.limits.maxExportBytes=64' "$ATD_FX_POLICY" > "$TMP/policy-small-export.json"
new_wd; EVAL_ATD_POLICY="$TMP/policy-small-export.json" expect_closed "blob larger than the remaining export budget is refused from its header" "$(atd_fx_config "$SHA_GOOD" "$SHA_REGRESS")" "remaining export byte limit"
new_wd; rm -rf "$WD/tests"; ATD_FX_CANDIDATE="$SHA_COSMETIC" atd_fx_case "$WD" "collide" "$ATD_FX_TEST_UPPER_BOUNDARY" node:test clamp.mjs; mv "$WD/tests" "$WD/src"
expect_closed "test file would overwrite a revision file" "$(atd_fx_config "$SHA_GOOD" "$SHA_COSMETIC" '{"testsDir":"src","testsRel":"src"}')" "collides"

echo "== live: drifted confinement is detected before test code runs =="
UNSAFE="atd-fx-unsafe-$$-$RANDOM"
trap 'docker rm -f "$UNSAFE" >/dev/null 2>&1 || true; rm -rf "$TMP"' EXIT
docker create --name "$UNSAFE" --pull never --network host -v "$TMP:/leak:rw" "$ATD_FX_PINNED_IMAGE" true >/dev/null
INSPECT="$(docker inspect "$UNSAFE")"; docker rm -f "$UNSAFE" >/dev/null
"$NODE" --input-type=module -e "
import fs from 'node:fs';
import { assertConfinement, loadPolicy } from '$ATD_FX_EVAL_DIR/discovery/sandbox.mjs';
const { policy } = loadPolicy();
const inspect = JSON.parse(fs.readFileSync(0, 'utf8'))[0];
try { assertConfinement(inspect, { policy, mounts: [], env: {}, kind: 'test' }); console.log('ACCEPTED'); process.exit(1); }
catch (e) { console.log(e.code + ': ' + e.message.slice(0, 200)); process.exit(e.code === 'sandbox_preflight' ? 0 : 2); }
" <<<"$INSPECT" >"$TMP/drift.out" 2>&1 && atd_fx_pass "host-network / writable-mount container rejected by assertConfinement ($(cut -c1-90 "$TMP/drift.out"))" || atd_fx_fail "unsafe container accepted: $(cat "$TMP/drift.out")"

echo "== live: host deadline kills runaway tests and leaves no containers =="
LOOP_TEST='import test from "node:test";
test("never finishes", () => { for (;;) {} });
'
new_wd; ATD_FX_CANDIDATE="$SHA_COSMETIC" atd_fx_case "$WD" "runaway" "$LOOP_TEST"
start=$(date +%s)
atd_fx_spawn "$WD" "$(atd_fx_config "$SHA_GOOD" "$SHA_COSMETIC" '{"timeoutSeconds":4}')"
elapsed=$(( $(date +%s) - start ))
if [[ "$ATD_FX_RC" == "0" ]]; then
  jq -e '.matrix=="ERROR" and .environmentEqual==true' "$WD/atd-out/differential.json" >/dev/null && atd_fx_pass "runaway test => matrix ERROR" || atd_fx_fail "runaway matrix: $(cat "$WD/atd-out/differential.json")"
  jq -e '.outcome=="error" and .errorClass=="timeout" and .timedOut==true' "$WD/atd-out/base.json" "$WD/atd-out/candidate.json" >/dev/null && atd_fx_pass "both records: error/timeout/timedOut" || atd_fx_fail "timeout records: $(jq -c '[.outcome,.errorClass,.timedOut]' "$WD/atd-out/base.json")"
  [[ "$elapsed" -lt 90 ]] && atd_fx_pass "bounded wall clock (${elapsed}s)" || atd_fx_fail "deadline not enforced (${elapsed}s)"
  atd_fx_verify_json "$WD/atd-out"; [[ "$ATD_FX_VRC" == "0" ]] && atd_fx_pass "timeout evidence is still validly signed" || atd_fx_fail "timeout evidence verify: $ATD_FX_VJSON"
else atd_fx_fail "runaway spawn exit $ATD_FX_RC: $(tail -3 "$ATD_FX_ERR")"; fi
WD_REAL="$(cd "$WD" && pwd -P)"
own="$(atd_fx_own_containers "$WD_REAL" "$WD/atd-out/base.json" "$WD/atd-out/candidate.json")"
[[ -f "$WD/atd-out/base.json" && -f "$WD/atd-out/candidate.json" ]] || atd_fx_fail "runaway records missing; own-container check would be vacuous"
[[ "${own%% *}" == "0" ]] && atd_fx_pass "this run's containers (by workdir label and attested execution ids) are all removed" || atd_fx_fail "this run leaked containers: $own"

atd_fx_finish
