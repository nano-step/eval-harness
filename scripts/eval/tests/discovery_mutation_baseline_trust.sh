#!/usr/bin/env bash
# A mutation baseline is trusted ONLY through its signed sandbox seal. Plain evidence.json / normalized.json sidecars are never
# authority: a forged baseline (plaintext only) fails BEFORE any Docker execution or output creation, an altered signed raw
# artifact fails, tampered sidecars cannot invent a kill (the summary is recomputed from the signed raw report), a different
# environment refuses comparison, and a run whose own seal cannot be verified is never "measured".
# Seals are produced by the real attest.mjs signer into a disposable EVAL_STATE_DIR; no Docker, model or Stryker is used.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EH_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
FIXTURE="$EH_ROOT/examples/discovery-pilot/collision"
for tool in node git jq ssh-keygen; do command -v "$tool" >/dev/null 2>&1 || { echo "SKIP: $tool required" >&2; exit 0; }; done
WORK="$(mktemp -d -t atd-baseline-trust.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
bash "$FIXTURE/build-fixture-repo.sh" "$WORK/repo" > "$WORK/fixture.json"
mkdir -p "$WORK/bin"; ln -s "$(command -v git)" "$WORK/bin/git"
export WORK EH_ROOT EVAL_STATE_DIR="$WORK/state" REPO BASE CLEAN
REPO="$(jq -r .repository "$WORK/fixture.json")"; BASE="$(jq -r .baseCommit "$WORK/fixture.json")"; CLEAN="$(jq -r .revisions.clean.commit "$WORK/fixture.json")"
unset ATD_TRUST ATD_SIGNING_KEY_FILE ATD_ALLOWED_SIGNERS_FILE || true

node --input-type=module - <<'JS'
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";

const D = `${process.env.EH_ROOT}/scripts/eval/discovery`;
const run = await import(`${D}/run-mutation.mjs`);
const attest = await import(`${D}/attest.mjs`);
const mut = await import(`${D}/mutation.mjs`);
const { analyzeChange } = await import(`${D}/risk.mjs`);
const { WORK, REPO, BASE, CLEAN } = process.env;
const STATE = process.env.EVAL_STATE_DIR;
const sha = b => createHash("sha256").update(b).digest("hex");
const env = { ...process.env };

const risk = analyzeChange({ repository: REPO, baseCommit: BASE, candidateCommit: CLEAN, spec: path.join(REPO, "SPEC.md"), existingTests: ["test/collision.test.ts"] });
const riskFile = path.join(WORK, "risk.json");
fs.writeFileSync(riskFile, JSON.stringify(risk));
const source = execFileSync("git", ["-C", REPO, "show", `${CLEAN}:src/collision.ts`], { encoding: "utf8" });
const target = risk.targets.find(t => t.file === "src/collision.ts");
const line = target.hunks[0].startLine;

// the exact Stryker configuration this run will use: obtained from the pipeline itself (it writes it before any Docker step)
const FULL_PATH = process.env.PATH;
process.env.PATH = path.join(WORK, "bin");
const probeOut = path.join(WORK, "probe");
const probeExit = await run.runMutationEvidence({ repo: REPO, commit: CLEAN, risk: riskFile, dependencies: path.join(WORK, "no-deps"), out: probeOut, "state-dir": STATE });
process.env.PATH = FULL_PATH;
assert.equal(probeExit, 13, "without a verifiable seal the run can never be measured");
const probe = JSON.parse(fs.readFileSync(path.join(probeOut, "evidence.json"), "utf8"));
assert.equal(probe.status, "unavailable");
assert.equal(probe.counts, null);
assert.equal(probe.score, null);
assert.ok(probe.seal && probe.seal.status !== "valid", "the missing seal is reported, not hidden");
const plan = JSON.parse(fs.readFileSync(path.join(probeOut, "plan.json"), "utf8"));
const configSha256 = sha(fs.readFileSync(path.join(probeOut, "stryker.config.json")));

function mutants(killedId5 = true) {
  const loc = (c0, c1) => ({ start: { line, column: c0 }, end: { line, column: c1 } });
  return [
    { id: "5", mutatorName: "EqualityOperator", replacement: "<=", status: killedId5 ? "Killed" : "Survived", location: loc(3, 12) },
    { id: "6", mutatorName: "EqualityOperator", replacement: ">=", status: "Survived", location: loc(14, 22) },
  ];
}
const baseRecord = {
  schema: "atd.execution-record/v1", candidateId: "mutation-baseline", side: "mutant", framework: "stryker",
  revision: { commit: CLEAN, treeSha256: sha("tree"), lockfileSha256: sha("lock") },
  testSha256: sha(""), testsTreeSha256: sha(""), depsSnapshotSha256: sha("deps"), lockfileSha256: sha("lock"),
  image: { ref: "node@sha256:abc", digest: "sha256:abc", id: "sha256:def" }, nodeVersion: "v22.0.0", profile: { id: "atd-sandbox/v1", policySha256: sha("policy") },
  argv: ["node", "/atd/exec.mjs", "mutate", `--max-mutants=${plan.maxMutants}`], env: { CI: "1", ATD_SEED: "1337", ATD_MAX_MUTANTS: String(plan.maxMutants) }, seed: 1337,
  mutationBudget: { maxMutants: plan.maxMutants, planned: 2, allowed: true, reportedMutants: 2 }, exitCode: 0, timedOut: false, outcome: "pass",
  startedAt: "2026-11-04T00:00:00.000Z", endedAt: "2026-11-04T00:01:00.000Z", durationMs: 60000,
};

/** A baseline directory whose sandbox/ is sealed by the real signer. `mutate` may alter the record before sealing. */
function sealedBaseline(name, { raw, record = {}, config = configSha256 } = {}) {
  const dir = path.join(WORK, name);
  const sb = path.join(dir, "sandbox");
  fs.mkdirSync(path.join(sb, "artifacts"), { recursive: true });
  const rawBytes = Buffer.from(JSON.stringify(raw ?? { schemaVersion: "1.0", files: { "src/collision.ts": { language: "typescript", source, mutants: mutants() } }, testFiles: {} }));
  fs.writeFileSync(path.join(sb, "artifacts", "mutant.mutation-report.json"), rawBytes);
  const rec = { ...baseRecord, executionId: `exec_${name}`, ...record, artifacts: [{ role: "stryker_report", path: "artifacts/mutant.mutation-report.json", sha256: sha(rawBytes) }] };
  const recBytes = attest.canonicalJson(rec);
  fs.writeFileSync(path.join(sb, "mutant.json"), recBytes);
  const signer = attest.resolveSigner({ stateDir: STATE, env });
  attest.sealAttestation(sb, {
    schema: "atd.attestation/v1", kind: "mutation", runner: { id: "atd-sandbox" }, ehRunId: "unknown", caseId: "unknown", candidateId: "mutation-baseline",
    executions: [{ executionId: rec.executionId, side: "mutant", recordFile: "mutant.json", recordSha256: sha(recBytes) }],
    candidateManifestSha256: config, specSha256: null, testSha256: rec.testSha256,
    artifacts: [{ path: "artifacts/mutant.mutation-report.json", sha256: sha(rawBytes) }], trust: signer.trust, signedAt: new Date().toISOString(),
  }, signer);
  return dir;
}
const load = (dir, over = {}) => run.loadSealedBaseline({ baselineDir: dir, expect: { commit: CLEAN, configSha256, maxMutants: plan.maxMutants }, riskReport: risk, plan, repo: REPO, commit: CLEAN, stateDir: STATE, env, normalizeStrykerReport: mut.normalizeStrykerReport, ...over });
const refuses = (fn, fragment) => { try { fn(); } catch (e) { assert.ok(e instanceof run.SealError, `${e}`); assert.ok(e.message.includes(fragment), `expected '${fragment}' in '${e.message}'`); return; } assert.fail(`a baseline that must be refused was accepted (${fragment})`); };

// 1. a genuine sealed baseline is loaded, and its counts are recomputed from the signed raw report
const good = sealedBaseline("good");
const loaded = load(good);
assert.deepEqual([loaded.summary.counts.killed, loaded.summary.counts.survived], [1, 1]);
assert.equal(loaded.seal.trust, "local-same-user");

// 2. tampered plaintext sidecars cannot invent a kill or a survivor: nothing is read from them
fs.writeFileSync(path.join(good, "evidence.json"), JSON.stringify({ status: "measured", counts: { killed: 0, survived: 2 }, mutants: [] }));
fs.writeFileSync(path.join(good, "normalized.json"), JSON.stringify({ forged: true }));
const again = load(good);
assert.deepEqual(again.summary.counts, loaded.summary.counts);
assert.equal(again.summary.mutants.find(m => m.id === "5").status, "Killed", "mutant 5 stays Killed whatever the sidecar says");
assert.equal(again.normalized.mutants.find(m => m.id === "5").outcome, "killed");

// 3. a forged baseline made ONLY of plaintext sidecars fails BEFORE Docker and before any output exists
const forged = path.join(WORK, "forged");
fs.mkdirSync(forged);
fs.writeFileSync(path.join(forged, "evidence.json"), JSON.stringify({ status: "measured", commit: CLEAN, configSha256, mutants: [] }));
fs.writeFileSync(path.join(forged, "normalized.json"), JSON.stringify({ forged: true }));
refuses(() => load(forged), "seal unavailable");
const forgedOut = path.join(WORK, "forged-out");
await assert.rejects(run.runMutationEvidence({ repo: REPO, commit: CLEAN, risk: riskFile, dependencies: path.join(WORK, "no-deps"), out: forgedOut, baseline: forged, "state-dir": STATE }), run.SealError);
assert.ok(!fs.existsSync(forgedOut), "no output may be created for an unverifiable baseline");

// 4. altered signed artifact / missing signature / wrong config binding / wrong revision are all refused
const altered = sealedBaseline("altered");
fs.appendFileSync(path.join(altered, "sandbox", "artifacts", "mutant.mutation-report.json"), " ");
refuses(() => load(altered), "digest mismatch");
const unsigned = sealedBaseline("unsigned");
fs.rmSync(path.join(unsigned, "sandbox", "attestation.json.sig"));
refuses(() => load(unsigned), "seal unavailable");
refuses(() => load(sealedBaseline("other-config", { config: sha("another config") })), "config binding");
refuses(() => load(sealedBaseline("other-commit", { record: { revision: { ...baseRecord.revision, commit: BASE } } })), "mutation commit");
refuses(() => load(sealedBaseline("with-tests", { record: { testsTreeSha256: sha("x"), testSha256: sha("x") } })), "tests tree");
refuses(() => load(sealedBaseline("failed-run", { record: { outcome: "error", errorClass: "infra", exitCode: 1 } })), "did not pass");

// 5. source preservation: embedded sources that differ from the mutation commit never become a baseline
const drift = { schemaVersion: "1.0", files: { "src/collision.ts": { language: "typescript", source: `${source}\n// drift`, mutants: mutants() } }, testFiles: {} };
refuses(() => load(sealedBaseline("drifted", { raw: drift })), "source preservation");

// 6. environment comparison covers the sealed environment and nothing physical
const a = { ...baseRecord, executionId: "a" };
assert.deepEqual(run.environmentDiffs(a, { ...a, executionId: "b", testsTreeSha256: sha("different tests"), testSha256: sha("different tests"), sandboxProfileSha256: sha("mount paths"), startedAt: "later", durationMs: 1 }), [], "tests tree, mount paths and timings are intended deltas");
const fields = r => run.environmentDiffs(a, r).map(d => d.field);
assert.deepEqual(fields({ ...a, image: { ...a.image, digest: "sha256:other" } }), ["image.digest"]);
assert.deepEqual(fields({ ...a, nodeVersion: "v24.0.0" }), ["nodeVersion"]);
assert.deepEqual(fields({ ...a, depsSnapshotSha256: sha("other deps") }), ["depsSnapshotSha256"]);
assert.deepEqual(fields({ ...a, seed: 7 }), ["seed"]);
assert.deepEqual(fields({ ...a, profile: { ...a.profile, policySha256: sha("other policy") } }), ["profile.policySha256"]);
assert.deepEqual(fields({ ...a, env: { ...a.env, TZ: "Asia/Tokyo" } }), ["env"]);
assert.deepEqual(fields({ ...a, revision: { ...a.revision, treeSha256: sha("other tree") } }), ["revision.treeSha256"]);
assert.deepEqual(fields({ ...a, image: { ref: a.image.ref, digest: a.image.digest } }), ["image.id"], "a missing field is a mismatch, not a match");

// A timeout contributes to Stryker's detected score but is not an assertion-killed coverage gap.
const before = { mutants: [{ key: "guard", status: "Survived" }] };
assert.equal(run.compareRaw(before, { mutants: [{ key: "guard", status: "Timeout" }] }).killedAfterSurvivalBefore, 0);
assert.equal(run.compareRaw(before, { mutants: [{ key: "guard", status: "Killed" }] }).killedAfterSurvivalBefore, 1);

// 7. tests overlay identity is replicated from the sandbox (flat and nested files)
const treeDir = path.join(WORK, "tree");
fs.mkdirSync(path.join(treeDir, "test", "nested"), { recursive: true });
fs.writeFileSync(path.join(treeDir, "a.test.ts"), "A");
fs.writeFileSync(path.join(treeDir, "test", "b.test.ts"), "B");
fs.writeFileSync(path.join(treeDir, "test", "nested", "c.test.ts"), "C");
const expected = sha(["a.test.ts", "test/b.test.ts", "test/nested/c.test.ts"].map((r, i) => `${r}\0${sha("ABC"[i])}\0`).join(""));
assert.equal(run.treeSha256(treeDir), expected);
console.log("baseline trust semantics ok");
JS

echo "PASS discovery_mutation_baseline_trust"
