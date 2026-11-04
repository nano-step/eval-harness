#!/usr/bin/env bash
# Generated tests are overlaid for the with-generated-tests mutation run at their REVISION-RELATIVE path.
# Real candidates follow the request convention `test/<id>.test.ts` (stored under candidates/<id>/tests/test/...), whose
# imports (`../src/collision`) only resolve from that location. This checks the selected layout actually resolves those
# imports against a real exported revision of the collision fixture, and that unsafe or unverified candidates are
# skipped with a reason. No Docker, model or Stryker is used.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EH_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
FIXTURE="$EH_ROOT/examples/discovery-pilot/collision"
for tool in node git jq; do command -v "$tool" >/dev/null 2>&1 || { echo "SKIP: $tool required" >&2; exit 0; }; done
WORK="$(mktemp -d -t atd-overlay.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

bash "$FIXTURE/build-fixture-repo.sh" "$WORK/repo" > "$WORK/fixture.json"
export REPO BASE CLEAN
REPO="$(jq -r .repository "$WORK/fixture.json")"; BASE="$(jq -r .baseCommit "$WORK/fixture.json")"; CLEAN="$(jq -r .revisions.clean.commit "$WORK/fixture.json")"
export WORK EH_ROOT

node --input-type=module - <<'JS'
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";

const { collectAcceptedTests } = await import(`${process.env.EH_ROOT}/scripts/eval/discovery/run-mutation.mjs`);
const { REPO, BASE, CLEAN, WORK } = process.env;
const MAX = 32 * 1024;
const sha = b => createHash("sha256").update(b).digest("hex");
const tracked = execFileSync("git", ["-C", REPO, "ls-tree", "-r", "--name-only", CLEAN], { encoding: "utf8" }).split("\n").filter(Boolean);

const TEST = `import { describe, expect, it } from "vitest";\nimport { overlaps } from "../src/collision";\n\ndescribe("edge", () => { it("touching is not overlap", () => { expect(overlaps({ x: 0, y: 0, width: 1, height: 1 }, { x: 1, y: 0, width: 1, height: 1 })).toBe(false); }); });\n`;

function makeRound(name, specs) {
  const round = path.join(WORK, name);
  const accepted = [];
  for (const s of specs) {
    const dir = path.join(round, "candidates", s.id);
    const bytes = Buffer.from(s.text ?? TEST);
    const manifest = JSON.stringify({
      schema: "atd.test-candidate/v1", id: s.id, testFile: s.testFile, testSha256: s.badHash ? "0".repeat(64) : sha(bytes),
      provenance: { baseCommit: s.baseCommit ?? BASE, candidateCommit: s.candidateCommit ?? CLEAN },
    });
    const file = path.join(dir, "tests", ...s.testFile.split("/"));
    if (s.symlinkTestsRoot) {
      fs.mkdirSync(path.join(round, "elsewhere", ...s.testFile.split("/").slice(0, -1)), { recursive: true });
      fs.writeFileSync(path.join(round, "elsewhere", ...s.testFile.split("/")), bytes);
      fs.mkdirSync(dir, { recursive: true });
      fs.symlinkSync(path.join(round, "elsewhere"), path.join(dir, "tests"));
    } else if (s.symlinkAncestor) {
      fs.mkdirSync(path.join(round, "elsewhere"), { recursive: true });
      fs.writeFileSync(path.join(round, "elsewhere", path.basename(s.testFile)), bytes);
      fs.mkdirSync(path.dirname(path.dirname(file)), { recursive: true });
      fs.symlinkSync(path.join(round, "elsewhere"), path.dirname(file));
    } else {
      fs.mkdirSync(path.dirname(file), { recursive: true });
      fs.writeFileSync(file, bytes);
    }
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(path.join(dir, "candidate.json"), manifest);
    const wd = path.join(round, "evidence", s.id, "workdir", "atd-out");
    fs.mkdirSync(wd, { recursive: true });
    fs.writeFileSync(path.join(wd, "attestation.json"), JSON.stringify({ testSha256: s.attested ?? sha(bytes), candidateManifestSha256: s.attestedManifest ?? sha(Buffer.from(manifest)) }));
    if (s.review) {
      const att = JSON.parse(fs.readFileSync(path.join(wd, "attestation.json"), "utf8"));
      att.specSha256 = "5".repeat(64);
      fs.writeFileSync(path.join(wd, "attestation.json"), JSON.stringify(att));
      const base = { schema_version: 1, verdict: "PASS", candidateId: s.id, testSha256: att.testSha256, specSha256: att.specSha256, candidateManifestSha256: att.candidateManifestSha256 };
      const body = s.review === "raw" ? "not json" : JSON.stringify({ ...base, ...(s.review === "fail" ? { verdict: "FAIL" } : {}), ...(s.review === "unbound" ? { testSha256: "1".repeat(64) } : {}), ...(s.review === "noverdict" ? { verdict: "MAYBE" } : {}) });
      fs.writeFileSync(path.join(round, "evidence", s.id, "workdir", "expectation-review.json"), body);
    }
    accepted.push(s.id);
  }
  fs.mkdirSync(round, { recursive: true });
  if (specs.some(s => s.symlinkCandidateDir)) {
    const real = path.join(round, "candidates", "swap-real");
    fs.renameSync(path.join(round, "candidates", "linked-dir"), real);
    fs.symlinkSync(real, path.join(round, "candidates", "linked-dir"));
  }
  fs.writeFileSync(path.join(round, "round-summary.json"), JSON.stringify({ baseCommit: BASE, candidateCommit: CLEAN, candidates: { acceptedIds: accepted } }));
  return round;
}
const verifyAs = (status, recomputed = true) => ({ caseDir }) => (recomputed ? { recomputed: true, status } : { recomputed: false, reason: "stub: not verifiable" });
const pick = (round, verifyCase) => collectAcceptedTests({ round, commit: CLEAN, tracked, verifyCase });
const reasons = r => Object.fromEntries(r.skipped.map(x => [x.candidateId, x.reason]));

// 1. nested revision-relative path: overlay at <rev>/test/<id>.test.ts so `../src/collision` resolves from there
const round = makeRound("r-ok", [{ id: "touch-edge", testFile: "test/touch-edge.test.ts" }]);
const ok = pick(round, verifyAs("PASS"));
assert.equal(ok.files.length, 1, JSON.stringify(ok.skipped));
assert.equal(ok.testsRel, ".", "overlaid at the revision root, not under a derived base");
assert.equal(ok.files[0].testFile, "test/touch-edge.test.ts");
assert.equal(ok.files[0].relInRoot, "test/touch-edge.test.ts", "the full revision-relative path is kept");
// materialize exactly as run-mutation does and overlay onto an exported revision at --tests-rel
const exportDir = path.join(WORK, "export");
fs.mkdirSync(exportDir);
execFileSync("bash", ["-c", `git -C "${REPO}" archive ${CLEAN} | tar -x -C "${exportDir}"`]);
const testsDir = path.join(WORK, "accepted-tests");
for (const f of ok.files) { const dest = path.join(testsDir, ...f.relInRoot.split("/")); fs.mkdirSync(path.dirname(dest), { recursive: true }); fs.writeFileSync(dest, f.bytes); }
fs.cpSync(testsDir, path.join(exportDir, ok.testsRel), { recursive: true });
assert.deepEqual(fs.readdirSync(testsDir), ["test"]);
const placed = path.join(exportDir, "test", "touch-edge.test.ts");
assert.ok(fs.existsSync(placed), "test overlaid at the revision-relative path");
const spec = /from "([^"]+)"/g; const imports = [...fs.readFileSync(placed, "utf8").matchAll(spec)].map(m => m[1]).filter(s => s.startsWith("."));
assert.deepEqual(imports, ["../src/collision"]);
assert.ok(fs.existsSync(path.resolve(path.dirname(placed), "../src/collision.ts")), "the relative import resolves against the exported revision");
assert.ok(!fs.existsSync(path.join(exportDir, "tests", "test")), "the test was not moved under tests/");
// the OLD (flat, under tests/) placement would break the import
assert.ok(!fs.existsSync(path.resolve(exportDir, "tests", "test", "../src/collision.ts")), "under tests/test/ the same import would not resolve");

// 2. unsafe / unverified candidates are skipped WITH a reason, never overlaid
const bad = makeRound("r-bad", [
  { id: "traversal", testFile: "test/../escape.test.ts" },
  { id: "dot", testFile: "./dot.test.ts" },
  { id: "dotgit", testFile: ".git/x.test.ts" },
  { id: "node-modules", testFile: "node_modules/x.test.ts" },
  { id: "symlink-ancestor", testFile: "test/sub/a.test.ts", symlinkAncestor: true },
  { id: "symlink-tests-root", testFile: "test/root.test.ts", symlinkTestsRoot: true },
  { id: "bad-hash", testFile: "test/bad-hash.test.ts", badHash: true },
  { id: "oversize", testFile: "test/oversize.test.ts", text: TEST + "// " + "x".repeat(MAX) },
  { id: "collides", testFile: "test/collision.test.ts" },
  { id: "wrong-commit", testFile: "test/wrong-commit.test.ts", candidateCommit: BASE },
  { id: "forged-attestation", testFile: "test/forged.test.ts", attested: "f".repeat(64) },
  { id: "swapped-metadata", testFile: "test/swapped.test.ts", attestedManifest: "e".repeat(64) },
  { id: "dup-a", testFile: "test/dup.test.ts" },
  { id: "dup-b", testFile: "test/dup.test.ts" },
]);
const res = pick(bad, verifyAs("PASS"));
assert.deepEqual(res.files.map(f => f.candidateId), ["dup-a"], JSON.stringify(res));
const why = reasons(res);
for (const [id, fragment] of Object.entries({
  traversal: "safe relative path", dot: "safe relative path", dotgit: "safe relative path", "node-modules": "safe relative path", "symlink-ancestor": "symbolic link", "symlink-tests-root": "not a plain directory",
  "bad-hash": "candidate.testSha256", oversize: "exceeds", collides: "already exists in the revision", "wrong-commit": "provenance", "forged-attestation": "signed attestation's testSha256",
  "swapped-metadata": "candidateManifestSha256", "dup-b": "already provides",
})) assert.ok(why[id]?.includes(fragment), `${id}: expected '${fragment}', got ${why[id]}`);
// a symlinked candidate directory is refused
const linked = makeRound("r-linked", [{ id: "linked-dir", testFile: "test/linked.test.ts", symlinkCandidateDir: true }]);
assert.ok(reasons(pick(linked, verifyAs("PASS")))["linked-dir"]?.includes("not a plain directory"));

// 2b. flat root files and several top-level directories are ALL accepted and their relative imports resolve from there
const multi = makeRound("r-multi", [
  { id: "flat", testFile: "flat.test.ts", text: TEST.replace("../src/collision", "./src/collision") },
  { id: "in-test", testFile: "test/in-test.test.ts" },
  { id: "in-spec", testFile: "spec/in-spec.test.ts" },
  { id: "nested", testFile: "test/nested/deep.test.ts", text: TEST.replace("../src/collision", "../../src/collision") },
]);
const many = pick(multi, verifyAs("PASS"));
assert.deepEqual(many.files.map(f => f.testFile).sort(), ["flat.test.ts", "spec/in-spec.test.ts", "test/in-test.test.ts", "test/nested/deep.test.ts"], JSON.stringify(many.skipped));
assert.equal(many.testsRel, ".");
const exportDir2 = path.join(WORK, "export2");
fs.mkdirSync(exportDir2);
execFileSync("bash", ["-c", `git -C "${REPO}" archive ${CLEAN} | tar -x -C "${exportDir2}"`]);
for (const f of many.files) {
  const dest = path.join(exportDir2, f.relInRoot);
  fs.mkdirSync(path.dirname(dest), { recursive: true });
  fs.writeFileSync(dest, f.bytes, { flag: "wx" });
  const spec = [...f.bytes.toString("utf8").matchAll(/from "(\.[^"]*)"/g)].map(m => m[1]);
  assert.equal(spec.length, 1);
  assert.ok(fs.existsSync(path.resolve(path.dirname(dest), `${spec[0]}.ts`)), `${f.testFile}: ${spec[0]} resolves against the exported revision`);
}

// 2c. a supplied operator review can only veto: bound FAIL is never overlaid, bound PASS and a missing review stay accepted,
//     malformed or unbound reviews are refused
const rv = makeRound("r-review", [
  { id: "no-review", testFile: "test/no-review.test.ts" },
  { id: "pass-review", testFile: "test/pass-review.test.ts", review: "pass" },
  { id: "fail-review", testFile: "test/fail-review.test.ts", review: "fail" },
  { id: "unbound-review", testFile: "test/unbound-review.test.ts", review: "unbound" },
  { id: "raw-review", testFile: "test/raw-review.test.ts", review: "raw" },
  { id: "noverdict-review", testFile: "test/noverdict-review.test.ts", review: "noverdict" },
]);
const rvRes = pick(rv, verifyAs("PASS"));
assert.deepEqual(rvRes.files.map(f => f.candidateId).sort(), ["no-review", "pass-review"], JSON.stringify(rvRes.skipped));
const rvWhy = reasons(rvRes);
assert.ok(rvWhy["fail-review"].includes("verdict is FAIL"));
assert.ok(rvWhy["unbound-review"].includes("not bound"));
assert.ok(rvWhy["raw-review"].includes("not valid JSON"));
assert.ok(rvWhy["noverdict-review"].includes("PASS|FAIL"));

// 3. no-run-for-failing-tests guard and independent verification are enforced
assert.equal(pick(round, verifyAs("FAIL")).files.length, 0);
assert.ok(reasons(pick(round, verifyAs("FAIL")))["touch-edge"].includes("never run"));
assert.ok(reasons(pick(round, verifyAs("PASS", false)))["touch-edge"].includes("could not be independently verified"));
// the REAL verifier refuses a preserved case without a grading manifest (a raw summary PASS is not authority)
assert.ok(reasons(collectAcceptedTests({ round, commit: CLEAN, tracked }))["touch-edge"].includes("could not be independently verified"));
// a round evaluated at another commit is refused outright
assert.throws(() => collectAcceptedTests({ round, commit: BASE, tracked, verifyCase: verifyAs("PASS") }), /not at the mutation commit/);
console.log("overlay semantics ok");
JS

echo "PASS discovery_mutation_overlay"
