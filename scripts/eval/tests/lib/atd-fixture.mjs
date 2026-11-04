#!/usr/bin/env node
// Test fixture builder: writes a workdir whose atd-out/ is signed by the REAL attest.mjs signer
// (EVAL_STATE_DIR must point at a disposable state dir). Used only by discovery grader tests.
//   node atd-fixture.mjs build --workdir=<dir> --base=pass|fail|error --candidate=pass|fail|error [options]
// options: --candidate-id= --run-id= --case-id= --env-diff --image-diff --same-commit --no-spec --no-ref
//          --quote= --spec-text= --review=approved|rejected|mismatch|none --error-class=
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { resolveSigner, sealAttestation, canonicalJson } from '../../discovery/attest.mjs';

const sha = (d) => crypto.createHash('sha256').update(d).digest('hex');
const args = {};
for (const a of process.argv.slice(3)) {
  const m = /^--([^=]+)(?:=(.*))?$/.exec(a);
  if (m) args[m[1]] = m[2] ?? true;
}
if (process.argv[2] !== 'build' || !args.workdir) {
  console.error('usage: atd-fixture.mjs build --workdir=<dir> --base= --candidate= [options]');
  process.exit(2);
}

const wd = path.resolve(args.workdir);
const candidateId = args['candidate-id'] || 'c1';
const runId = args['run-id'] || 'run-1';
const caseId = args['case-id'] || 'case-1';
const baseCommit = args['base-commit'] || 'a'.repeat(40);
const candidateCommit = args['candidate-commit'] || 'b'.repeat(40);
if (!/^[0-9a-f]{40}$/.test(baseCommit) || !/^[0-9a-f]{40}$/.test(candidateCommit)) { console.error('commits must be 40 hex chars'); process.exit(2); }
const quote = args.quote || 'Rectangles that only touch at an edge do not overlap.';
const specText = args['spec-text'] || `# Collision spec\n\n${quote}\nZero-size rectangles never overlap.\n`;
const testText = args['test-text'] || "import test from 'node:test';\nimport assert from 'node:assert/strict';\ntest('touching edges', () => { assert.equal(1, 1); });\n";

fs.mkdirSync(path.join(wd, 'tests'), { recursive: true });
const out = path.join(wd, 'atd-out');
fs.rmSync(out, { recursive: true, force: true });
fs.mkdirSync(path.join(out, 'artifacts'), { recursive: true });

fs.writeFileSync(path.join(wd, 'tests', 't.test.mjs'), testText);
const testSha = sha(testText);
if (!args['no-spec']) fs.writeFileSync(path.join(wd, 'SPEC.md'), specText);
const specSha = args['no-spec'] ? null : sha(specText);

const manifest = {
  schema: 'atd.test-candidate/v1',
  id: candidateId,
  strategy: 'intent_aware',
  targetFile: 'src/collision.ts',
  testFile: 't.test.mjs',
  framework: 'node:test',
  testSha256: testSha,
  requirementRef: args['no-ref'] ? null : { specSha256: specSha, quote },
  failureHypothesis: 'touching edges may be treated as overlap',
  provenance: { baseCommit: baseCommit, candidateCommit: candidateCommit, sourceDiffHash: 'c'.repeat(64), generatorRole: 'implement', promptSha256: 'd'.repeat(64) },
  trust: 'untrusted',
};
const manifestBytes = JSON.stringify(manifest, null, 2) + '\n';
fs.writeFileSync(path.join(wd, 'candidate.json'), manifestBytes);
const manifestSha = sha(manifestBytes);

const policySha = 'e'.repeat(64);
function record(side, outcome) {
  const stdout = `stdout of ${side}\n${crypto.randomUUID()}\n`;
  const stdoutPath = `artifacts/${side}.stdout`;
  fs.writeFileSync(path.join(out, stdoutPath), stdout);
  const envDiff = args['env-diff'] && side === 'candidate';
  const imgDiff = args['image-diff'] && side === 'candidate';
  const rec = {
    schema: 'atd.execution-record/v1',
    executionId: crypto.randomUUID(),
    candidateId,
    side,
    revision: { commit: side === 'base' || args['same-commit'] ? baseCommit : candidateCommit, treeSha256: sha(`tree-${side}`), lockfileSha256: sha('lock') },
    testSha256: testSha,
    depsSnapshotSha256: sha('deps'),
    lockfileSha256: sha('lock'),
    image: { ref: 'node:22-bookworm-slim', digest: imgDiff ? `sha256:${'9'.repeat(64)}` : `sha256:${'8'.repeat(64)}` },
    nodeVersion: 'v22.0.0',
    profile: { id: 'atd-sandbox/v1', policySha256: policySha },
    argv: ['node', '--test', '/work/tests/t.test.mjs'],
    env: { TZ: 'UTC', LANG: 'C', ...(envDiff ? { EXTRA: '1' } : {}) },
    seed: 7,
    startedAt: '2026-11-03T00:00:00.000Z',
    endedAt: '2026-11-03T00:00:01.000Z',
    durationMs: 1000,
    exitCode: outcome === 'pass' ? 0 : 1,
    timedOut: false,
    outcome,
    artifacts: [{ role: 'stdout', path: stdoutPath, sha256: sha(stdout) }],
  };
  if (outcome === 'error') rec.errorClass = args['error-class'] || 'compile';
  return rec;
}
const baseRec = record('base', args.base || 'pass');
const candRec = record('candidate', args.candidate || 'pass');
const matrix = [baseRec.outcome, candRec.outcome].includes('error') ? 'ERROR' : `${baseRec.outcome.toUpperCase()}->${candRec.outcome.toUpperCase()}`;
const baseBytes = canonicalJson(baseRec);
const candBytes = canonicalJson(candRec);
fs.writeFileSync(path.join(out, 'base.json'), baseBytes);
fs.writeFileSync(path.join(out, 'candidate.json'), candBytes);
const envEqual = !args['env-diff'] && !args['image-diff'];
const diff = { schema: 'atd.differential/v1', candidateId, base: baseRec.executionId, candidate: candRec.executionId, matrix, environmentEqual: envEqual };
const diffBytes = canonicalJson(diff);
fs.writeFileSync(path.join(out, 'differential.json'), diffBytes);

const signer = resolveSigner();
const artifacts = [...baseRec.artifacts, ...candRec.artifacts].map((a) => ({ path: a.path, sha256: a.sha256 }));
sealAttestation(out, {
  schema: 'atd.attestation/v1',
  ehRunId: args['no-run-binding'] ? undefined : runId,
  caseId: args['no-run-binding'] ? undefined : caseId,
  candidateId,
  trust: signer.trust,
  executions: [
    { executionId: baseRec.executionId, side: 'base', recordFile: 'base.json', recordSha256: sha(baseBytes) },
    { executionId: candRec.executionId, side: 'candidate', recordFile: 'candidate.json', recordSha256: sha(candBytes) },
  ],
  differentialSha256: sha(diffBytes),
  candidateManifestSha256: manifestSha,
  specSha256: specSha,
  testSha256: testSha,
  artifacts,
}, signer);

// Optional operator review, bound to the ATTESTED values.
const review = args.review || 'none';
if (review !== 'none') {
  const rec = {
    schema_version: 1,
    verdict: review === 'rejected' ? 'FAIL' : 'PASS',
    reviewer: 'operator',
    rubric_version: 'expectation-v1',
    timestamp: '2026-11-03T00:00:00Z',
    rationale: 'assertion matches the quoted requirement',
    candidateId,
    testSha256: testSha,
    specSha256: specSha,
    candidateManifestSha256: review === 'mismatch' ? 'a'.repeat(64) : manifestSha,
  };
  fs.writeFileSync(path.join(wd, 'expectation-review.json'), JSON.stringify(rec, null, 2) + '\n');
}
process.stdout.write(JSON.stringify({ candidateId, matrix, baseExecutionId: baseRec.executionId, candidateExecutionId: candRec.executionId, testSha256: testSha, specSha256: specSha, manifestSha256: manifestSha }) + '\n');
