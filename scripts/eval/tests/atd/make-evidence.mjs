// make-evidence.mjs — builds a structurally complete atd-out directory (records, differential,
// artifacts) and seals it with the REAL signer (resolveSigner/sealAttestation from attest.mjs), so the
// attestation suites can tamper with genuine signed evidence without needing Docker.
//   node make-evidence.mjs <out-dir> [--malformed-artifact-path]
import fs from 'node:fs';
import path from 'node:path';
import { canonicalJson, resolveSigner, sealAttestation, sha256Hex } from '../../discovery/attest.mjs';

const outDir = process.argv[2];
const malformed = process.argv.includes('--malformed-artifact-path');
const hex = (n) => sha256Hex(`fixture-${n}`);
fs.mkdirSync(path.join(outDir, 'artifacts'), { recursive: true });

const write = (rel, content) => { fs.writeFileSync(path.join(outDir, rel), content); return sha256Hex(content); };
const record = (side, outcome, extra = {}) => {
  const rep = `{"side":"${side}","outcome":"${outcome}"}\n`;
  const repSha = write(`artifacts/${side}.node-test.json`, rep);
  const execId = `exec_${side === 'base' ? '11111111-1111-4111-8111-111111111111' : '22222222-2222-4222-8222-222222222222'}`;
  const rec = {
    schema: 'atd.execution-record/v1', executionId: execId, candidateId: 'cand-1', side,
    revision: { commit: hex(`rev-${side}`).slice(0, 40), treeSha256: hex(`tree-${side}`), lockfileSha256: null },
    testSha256: hex('test'), testsTreeSha256: hex('tests'), depsSnapshotSha256: null, lockfileSha256: null,
    image: { ref: 'node@sha256:' + hex('img'), digest: `sha256:${hex('img')}`, id: `sha256:${hex('imgid')}` }, nodeVersion: 'v22.0.0',
    profile: { id: 'atd-sandbox/v1', policySha256: hex('policy') }, sandboxProfileSha256: hex('profile'),
    argv: ['node', '/atd/exec.mjs'], env: { CI: '1' }, seed: 1, framework: 'node:test',
    startedAt: '2026-11-03T00:00:00.000Z', endedAt: '2026-11-03T00:00:01.000Z', durationMs: 1000, exitCode: outcome === 'pass' ? 0 : 1, timedOut: false, outcome,
    artifacts: [{ role: 'node_test_json', path: `artifacts/${side}.node-test.json`, sha256: repSha }], ...extra,
  };
  const sha = write(`${side}.json`, canonicalJson(rec));
  return { rec, sha, repSha };
};
const base = record('base', 'pass');
const cand = record('candidate', 'fail');
const differential = { schema: 'atd.differential/v1', candidateId: 'cand-1', base: base.rec.executionId, candidate: cand.rec.executionId, matrix: 'PASS->FAIL', environmentEqual: true, environmentMismatch: [] };
const diffSha = write('differential.json', canonicalJson(differential));

const artifacts = [
  { path: 'artifacts/base.node-test.json', sha256: base.repSha },
  { path: 'artifacts/candidate.node-test.json', sha256: cand.repSha },
];
if (malformed) artifacts[0] = { path: 'artifacts/../../escape', sha256: base.repSha };
const signer = resolveSigner({ forbiddenRoots: [outDir] });
const attestation = {
  schema: 'atd.attestation/v1', kind: 'differential',
  runner: { id: 'atd-sandbox', scriptSha256: hex('script'), policySha256: hex('policy') },
  ehRunId: 'run-1', caseId: 'case-1', candidateId: 'cand-1',
  executions: [
    { executionId: base.rec.executionId, side: 'base', recordFile: 'base.json', recordSha256: base.sha },
    { executionId: cand.rec.executionId, side: 'candidate', recordFile: 'candidate.json', recordSha256: cand.sha },
  ],
  differentialSha256: diffSha, candidateManifestSha256: hex('manifest'), specSha256: hex('spec'), testSha256: hex('test'),
  artifacts, trust: signer.trust, signedAt: '2026-11-03T00:00:02.000Z',
};
const res = sealAttestation(outDir, attestation, signer);
process.stdout.write(`${JSON.stringify({ trust: signer.trust, ...res })}\n`);
