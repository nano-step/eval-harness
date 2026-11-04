#!/usr/bin/env node
// scripts/eval/discovery/classify.mjs — conservative differential classification for Autonomous
// Test Discovery (atd.finding/v1). Dependency-free Node ESM.
//
// Two layers:
//   * summarizeEvidence(): reads a runner out-dir AFTER the caller verified its signature with
//     atd_verify, re-checks every hash binding, and RECOMPUTES outcomes/matrix/environment equality
//     from the signed execution records. No claimed boolean from a model, manifest or differential
//     file is trusted.
//   * classifyDifferential(): pure. Maps (outcomes, environment, requirement support, stability) to a
//     finding classification and an existing eval-harness check status.
//
// Statuses (existing vocabulary only): PASS | FAIL | PENDING | UNAVAILABLE | ERROR.
//   VERIFIED_REGRESSION  -> FAIL         (only after >=3 identical, fresh, authenticated samples)
//   SUSPECTED_REGRESSION -> PENDING      (or provisional FAIL in phase "score" to trigger sampling)
//   INCONCLUSIVE         -> UNAVAILABLE  (ERROR when evidence is tampered/invalid)
//   EXPECTED_CHANGE / EXISTING_FAILURE / no finding -> PASS
//
// Semantic limitation (documented, not hidden): an exact quote of the spec only LINKS a test to a
// requirement; it does not prove the assertion states that requirement. requirementSupported is
// true only when the exact quote AND an operator-supplied review record (verdict PASS, bound to the
// attested candidate/test/spec hashes) both hold.

import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';

export const FINDING_SCHEMA = 'atd.finding/v1';
export const MIN_STABILITY_SAMPLES = 3;
const MAX_JSON_BYTES = 8 * 1024 * 1024;
const MIN_QUOTE_CHARS = 12;
const OUTCOMES = new Set(['pass', 'fail', 'error']);
const SEVERITIES = new Set(['low', 'medium', 'high']);
const ID_RE = /^[A-Za-z0-9][A-Za-z0-9._-]*$/;
const SHA_RE = /^[0-9a-f]{64}$/;

// ---------------------------------------------------------------- helpers

export function canonicalize(value) {
  if (value === null || typeof value !== 'object') return JSON.stringify(value === undefined ? null : value);
  if (Array.isArray(value)) return '[' + value.map(canonicalize).join(',') + ']';
  const keys = Object.keys(value).filter((k) => value[k] !== undefined).sort();
  return '{' + keys.map((k) => JSON.stringify(k) + ':' + canonicalize(value[k])).join(',') + '}';
}

export function sha256Hex(data) {
  return crypto.createHash('sha256').update(data).digest('hex');
}

export function computeMatrix(base, candidate) {
  if (!OUTCOMES.has(base) || !OUTCOMES.has(candidate)) return 'ERROR';
  if (base === 'error' || candidate === 'error') return 'ERROR';
  return `${base.toUpperCase()}->${candidate.toUpperCase()}`;
}

function outcomeOf(v) {
  if (v && typeof v === 'object') return v.outcome ?? null;
  return v ?? null;
}

function statusToPassed(status) {
  if (status === 'PASS') return true;
  if (status === 'FAIL' || status === 'ERROR') return false;
  return null;
}

// ------------------------------------------------------- evidence summary

function invalid(reason, extra = {}) {
  return { status: 'invalid', reason, ...extra };
}

// Streaming digest for potentially large artifacts (never loads the file into memory).
function hashRegularFile(p) {
  let st;
  try {
    st = fs.lstatSync(p);
  } catch (e) {
    return { ok: false, reason: `unreadable: ${e.code || e.message}` };
  }
  if (st.isSymbolicLink() || !st.isFile()) return { ok: false, reason: 'not a regular file' };
  const hash = crypto.createHash('sha256');
  const fd = fs.openSync(p, 'r');
  try {
    const buf = Buffer.allocUnsafe(1 << 20);
    for (;;) {
      const n = fs.readSync(fd, buf, 0, buf.length, null);
      if (n === 0) break;
      hash.update(buf.subarray(0, n));
    }
  } finally {
    fs.closeSync(fd);
  }
  return { ok: true, sha256: hash.digest('hex') };
}

function readRegular(p, maxBytes = MAX_JSON_BYTES) {
  let st;
  try {
    st = fs.lstatSync(p);
  } catch (e) {
    return { ok: false, missing: e.code === 'ENOENT', reason: `${path.basename(p)} unreadable: ${e.code || e.message}` };
  }
  if (st.isSymbolicLink()) return { ok: false, missing: false, reason: `${path.basename(p)} is a symlink` };
  if (!st.isFile()) return { ok: false, missing: false, reason: `${path.basename(p)} is not a regular file` };
  if (st.size > maxBytes) return { ok: false, missing: false, reason: `${path.basename(p)} exceeds ${maxBytes} bytes` };
  const bytes = fs.readFileSync(p);
  return { ok: true, bytes, sha256: sha256Hex(bytes) };
}

function readJson(p) {
  const r = readRegular(p);
  if (!r.ok) return r;
  try {
    return { ...r, value: JSON.parse(r.bytes.toString('utf8')) };
  } catch (e) {
    return { ok: false, missing: false, reason: `${path.basename(p)} is not valid JSON` };
  }
}

function listFiles(root, rel = '') {
  const out = [];
  let entries = [];
  try {
    entries = fs.readdirSync(path.join(root, rel), { withFileTypes: true });
  } catch {
    return out;
  }
  for (const e of entries.sort((a, b) => (a.name < b.name ? -1 : 1))) {
    const r = rel ? `${rel}/${e.name}` : e.name;
    if (e.isDirectory()) out.push(...listFiles(root, r));
    else out.push(r);
  }
  return out;
}

function within(root, p) {
  const rr = path.resolve(root);
  const pp = path.resolve(p);
  return pp === rr || pp.startsWith(rr + path.sep);
}

function recordProblem(rec, side) {
  if (!rec || typeof rec !== 'object') return `${side} record is not an object`;
  if (rec.schema !== 'atd.execution-record/v1') return `${side} record schema is ${JSON.stringify(rec.schema)}`;
  if (typeof rec.executionId !== 'string' || !rec.executionId) return `${side} record lacks executionId`;
  if (rec.side !== side) return `${side} record declares side ${JSON.stringify(rec.side)}`;
  if (!OUTCOMES.has(rec.outcome)) return `${side} record outcome ${JSON.stringify(rec.outcome)} is not pass|fail|error`;
  if (typeof rec.testSha256 !== 'string' || !SHA_RE.test(rec.testSha256)) return `${side} record lacks testSha256`;
  if (!rec.revision || typeof rec.revision.commit !== 'string') return `${side} record lacks revision.commit`;
  if (!rec.image || typeof rec.image.digest !== 'string' || !rec.image.digest) return `${side} record lacks image.digest`;
  return null;
}

function envMismatch(a, b) {
  const fields = [];
  const cmp = (name, x, y) => {
    if (canonicalize(x) !== canonicalize(y)) fields.push(name);
  };
  cmp('image.digest', a.image?.digest, b.image?.digest);
  cmp('nodeVersion', a.nodeVersion, b.nodeVersion);
  cmp('depsSnapshotSha256', a.depsSnapshotSha256, b.depsSnapshotSha256);
  cmp('lockfileSha256', a.lockfileSha256, b.lockfileSha256);
  cmp('revision.lockfileSha256', a.revision?.lockfileSha256, b.revision?.lockfileSha256);
  cmp('env', a.env, b.env);
  cmp('seed', a.seed ?? null, b.seed ?? null);
  cmp('argv', a.argv, b.argv);
  cmp('profile', a.profile, b.profile);
  cmp('testSha256', a.testSha256, b.testSha256);
  return fields;
}

function resolveRecordArtifact(outDir, relPath) {
  if (typeof relPath !== 'string' || !relPath || path.isAbsolute(relPath) || relPath.split(/[\\/]/).includes('..')) return null;
  const candidates = [relPath];
  if (relPath.startsWith('atd-out/')) candidates.push(relPath.slice('atd-out/'.length));
  for (const c of candidates) {
    const full = path.join(outDir, c);
    if (within(outDir, full) && fs.existsSync(full)) return full;
  }
  return null;
}

// Validates an operator-supplied expectation review bound to the ATTESTED hashes.
function reviewStatus(workdir, reviewFile, attested) {
  if (!reviewFile) return { status: 'missing', reason: 'no expectation review configured' };
  const full = path.resolve(workdir, reviewFile);
  if (path.isAbsolute(reviewFile) || !within(workdir, full) || full === path.resolve(workdir)) {
    return { status: 'invalid', reason: 'review path escapes the workdir' };
  }
  const r = readJson(full);
  if (!r.ok) {
    if (r.missing) return { status: 'missing', reason: 'expectation review not supplied' };
    return { status: 'invalid', reason: r.reason };
  }
  const rec = r.value;
  if (!rec || typeof rec !== 'object' || Array.isArray(rec)) return { status: 'invalid', reason: 'review record is not an object' };
  const verdict = String(rec.verdict ?? '').toUpperCase();
  for (const k of ['reviewer', 'rubric_version', 'timestamp']) {
    if (typeof rec[k] !== 'string' || !rec[k].trim()) return { status: 'invalid', reason: `review record lacks ${k}` };
  }
  if (verdict !== 'PASS' && verdict !== 'FAIL') return { status: 'invalid', reason: 'review verdict must be PASS or FAIL' };
  for (const k of ['candidateId', 'testSha256', 'specSha256', 'candidateManifestSha256']) {
    if (attested[k] == null || rec[k] !== attested[k]) {
      return { status: 'invalid', reason: `review ${k} does not match the attested value`, reviewSha256: r.sha256 };
    }
  }
  return {
    status: verdict === 'PASS' ? 'approved' : 'rejected',
    reason: verdict === 'PASS' ? 'review approves the assertion against the quoted requirement' : 'review rejected the assertion',
    reviewer: rec.reviewer,
    rubricVersion: rec.rubric_version,
    timestamp: rec.timestamp,
    reviewSha256: r.sha256,
  };
}

/**
 * Summarize one runner out-dir. The caller MUST have run atd_verify first and pass its JSON/exit.
 * opts: { outDir, workdir, candidateFile, specFile, testsDir, reviewFile, verify, expected }
 *   verify: { status: 'valid'|'unavailable'|'invalid', reason, trust, attestationSha256, executionIds }
 *   expected: { runId, caseId } optional binding to the current run.
 * Never throws; always returns { status: 'valid'|'unavailable'|'invalid', ... }.
 */
export function summarizeEvidence(opts) {
  try {
    return summarizeEvidenceUnsafe(opts);
  } catch (e) {
    return invalid(`evidence summarization failed: ${e.message}`);
  }
}

function summarizeEvidenceUnsafe(opts) {
  // Compare canonical (realpath) locations on both sides: callers may pass a symlinked temp root (macOS /var -> /private/var)
  // for one and a resolved path for the other. Symlinked evidence itself is still rejected by the verifier and lstat checks.
  const realOr = (p) => {
    try {
      return fs.realpathSync(path.resolve(p));
    } catch {
      return path.resolve(p);
    }
  };
  const outDir = realOr(opts.outDir);
  const workdir = realOr(opts.workdir);
  const verify = opts.verify || { status: 'invalid', reason: 'no verifier result supplied' };
  if (verify.status === 'unavailable') return { status: 'unavailable', reason: verify.reason || 'evidence unavailable' };
  if (verify.status !== 'valid') return invalid(verify.reason || 'attestation verification failed');
  if (!within(workdir, outDir) || outDir === workdir) return invalid('out-dir escapes the workdir');

  const baseF = readJson(path.join(outDir, 'base.json'));
  const candF = readJson(path.join(outDir, 'candidate.json'));
  const diffF = readJson(path.join(outDir, 'differential.json'));
  const attF = readJson(path.join(outDir, 'attestation.json'));
  for (const [n, f] of [['base.json', baseF], ['candidate.json', candF], ['differential.json', diffF], ['attestation.json', attF]]) {
    if (!f.ok) return invalid(`verified evidence unreadable: ${f.reason}`);
    if (!f.value || typeof f.value !== 'object' || Array.isArray(f.value)) return invalid(`${n} is not an object`);
  }
  const base = baseF.value;
  const cand = candF.value;
  const diff = diffF.value;
  const att = attF.value;

  if (att.schema !== 'atd.attestation/v1') return invalid('attestation schema is not atd.attestation/v1');
  if (diff.schema !== 'atd.differential/v1') return invalid('differential schema is not atd.differential/v1');
  const pb = recordProblem(base, 'base');
  if (pb) return invalid(pb);
  const pc = recordProblem(cand, 'candidate');
  if (pc) return invalid(pc);
  if (base.executionId === cand.executionId) return invalid('base and candidate share one executionId');

  // Hash binding re-check, independent of the verifier implementation.
  const execs = Array.isArray(att.executions) ? att.executions : [];
  const bind = (rec, file) => {
    const e = execs.find((x) => x && x.executionId === rec.executionId);
    return e && e.recordSha256 === file.sha256;
  };
  if (!bind(base, baseF)) return invalid('base record digest is not bound by the attestation');
  if (!bind(cand, candF)) return invalid('candidate record digest is not bound by the attestation');
  if (att.differentialSha256 !== diffF.sha256) return invalid('differential digest is not bound by the attestation');
  if (diff.base !== base.executionId || diff.candidate !== cand.executionId) return invalid('differential references different executions than the signed records');
  if (verify.executionIds && Array.isArray(verify.executionIds) && verify.executionIds.length) {
    const have = new Set(verify.executionIds);
    if (!have.has(base.executionId) || !have.has(cand.executionId)) return invalid('verifier executionIds disagree with records');
  }
  if (base.testSha256 !== cand.testSha256) return invalid('base and candidate ran different tests');
  if (att.testSha256 != null && att.testSha256 !== base.testSha256) return invalid('attested testSha256 differs from execution records');
  if (diff.candidateId != null && att.candidateId != null && diff.candidateId !== att.candidateId) return invalid('differential and attestation disagree on candidateId');
  const candidateId = att.candidateId ?? diff.candidateId ?? cand.candidateId ?? base.candidateId;
  if (typeof candidateId !== 'string' || !ID_RE.test(candidateId)) return invalid('candidateId is missing or malformed');
  if (base.candidateId != null && base.candidateId !== candidateId) return invalid('base record candidateId differs');
  if (cand.candidateId != null && cand.candidateId !== candidateId) return invalid('candidate record candidateId differs');

  // Run/case binding: a signed attestation copied from another run must not count here.
  const expected = opts.expected || {};
  // When the caller knows the current run/case, the signed attestation MUST carry exactly those ids.
  if (expected.runId && att.ehRunId !== expected.runId) return invalid(`attestation bound to run ${JSON.stringify(att.ehRunId ?? null)}, expected ${expected.runId}`);
  if (expected.caseId && att.caseId !== expected.caseId) return invalid(`attestation bound to case ${JSON.stringify(att.caseId ?? null)}, expected ${expected.caseId}`);

  // Artifact confinement + digests.
  for (const rec of [base, cand]) {
    for (const a of Array.isArray(rec.artifacts) ? rec.artifacts : []) {
      const full = resolveRecordArtifact(outDir, a?.path);
      if (!full) return invalid(`artifact ${JSON.stringify(a?.path)} missing or escapes atd-out`);
      const r = hashRegularFile(full);
      if (!r.ok) return invalid(`artifact ${a.path}: ${r.reason}`);
      if (r.sha256 !== a.sha256) return invalid(`artifact ${a.path} digest mismatch`);
    }
  }

  // Recompute, do not trust, matrix and environment equality.
  const matrix = computeMatrix(base.outcome, cand.outcome);
  if (diff.matrix != null && diff.matrix !== matrix) return invalid(`claimed matrix ${diff.matrix} contradicts signed records (${matrix})`);
  const mismatch = envMismatch(base, cand);
  const environmentEqual = mismatch.length === 0;
  if (diff.environmentEqual === true && !environmentEqual) return invalid(`claimed environmentEqual contradicts signed records (${mismatch.join(',')})`);
  const sameRevision = base.revision.commit === cand.revision.commit;
  if (sameRevision) mismatch.push('revision.commit(identical sides)');
  const effectiveEnvEqual = environmentEqual && !sameRevision && diff.environmentEqual !== false;

  // Modified test after signing.
  const testsDir = opts.testsDir || 'tests';
  const candidateFile = opts.candidateFile || 'candidate.json';
  const specFile = opts.specFile || 'SPEC.md';
  const manifestF = readJson(path.resolve(workdir, candidateFile));
  const specF = readRegular(path.resolve(workdir, specFile));
  let testFile = '';
  let targetFile = '';
  let manifest = null;

  if (att.candidateManifestSha256 != null) {
    if (!manifestF.ok) return invalid(`attested candidate manifest ${candidateFile} unreadable: ${manifestF.reason}`);
    if (manifestF.sha256 !== att.candidateManifestSha256) return invalid('candidate manifest changed after attestation');
  }
  if (manifestF.ok && manifestF.value && typeof manifestF.value === 'object') {
    manifest = manifestF.value;
    if (typeof manifest.testFile === 'string') testFile = manifest.testFile;
    if (typeof manifest.targetFile === 'string') targetFile = manifest.targetFile;
  }
  if (att.specSha256 != null) {
    if (!specF.ok) return invalid(`attested spec ${specFile} unreadable: ${specF.reason}`);
    if (specF.sha256 !== att.specSha256) return invalid('spec changed after attestation');
  }
  // The executable reproducer must exist and be the attested bytes.
  if (!testFile || path.isAbsolute(testFile) || testFile.split(/[\\/]/).includes('..')) return invalid('executable reproducer is not identifiable (candidate manifest lacks a safe testFile)');
  const tf = readRegular(path.resolve(workdir, testsDir, testFile));
  if (!tf.ok) return invalid(`executable reproducer ${testsDir}/${testFile} missing or unreadable: ${tf.reason}`);
  if (tf.sha256 !== base.testSha256) return invalid('test file changed after attestation');

  // Requirement link (exact quote) — necessary, NOT sufficient (see header).
  let link = { exactQuote: false, reason: 'no_requirement_ref' };
  if (!manifestF.ok) link = { exactQuote: false, reason: 'candidate_manifest_missing' };
  else if (att.candidateManifestSha256 == null) link = { exactQuote: false, reason: 'candidate_manifest_unbound' };
  else if (manifest.schema !== 'atd.test-candidate/v1') link = { exactQuote: false, reason: 'candidate_manifest_schema' };
  else if (manifest.id !== candidateId) link = { exactQuote: false, reason: 'candidate_manifest_id_mismatch' };
  else if (manifest.testSha256 !== base.testSha256) link = { exactQuote: false, reason: 'candidate_manifest_test_mismatch' };
  else if (!manifest.requirementRef || typeof manifest.requirementRef !== 'object') link = { exactQuote: false, reason: 'no_requirement_ref' };
  else if (!specF.ok) link = { exactQuote: false, reason: 'spec_missing' };
  else if (att.specSha256 == null) link = { exactQuote: false, reason: 'spec_unbound' };
  else {
    const q = manifest.requirementRef.quote;
    const ref = manifest.requirementRef.specSha256;
    const spec = specF.bytes.toString('utf8');
    if (ref !== specF.sha256) link = { exactQuote: false, reason: 'spec_digest_mismatch' };
    else if (typeof q !== 'string' || q.trim().length < MIN_QUOTE_CHARS || !/[A-Za-z]/.test(q)) link = { exactQuote: false, reason: 'quote_too_short' };
    else if (!spec.includes(q)) link = { exactQuote: false, reason: 'quote_not_in_spec' };
    else link = { exactQuote: true, reason: 'quote_found_verbatim' };
  }

  const attested = {
    candidateId,
    testSha256: base.testSha256,
    specSha256: att.specSha256 ?? null,
    candidateManifestSha256: att.candidateManifestSha256 ?? null,
  };
  const review = link.exactQuote ? reviewStatus(workdir, opts.reviewFile, attested) : { status: 'missing', reason: 'no verified requirement link to review' };
  let requirementSupported = link.exactQuote && review.status === 'approved';
  let requirementReason = !link.exactQuote ? link.reason : review.status === 'approved' ? 'supported' : `semantic_review_${review.status}`;
  const files = listFiles(outDir);
  // Trust comes from the verifier's signer-derived metadata. The attestation's own label must agree; it can never upgrade.
  if (verify.trust != null && att.trust != null && verify.trust !== att.trust) return invalid(`attestation trust label ${att.trust} disagrees with the verifier (${verify.trust})`);
  const trust = verify.trust ?? null;
  const fingerprint = sha256Hex(
    canonicalize({
      candidateId, matrix, base: base.outcome, cand: cand.outcome, be: base.errorClass ?? null, ce: cand.errorClass ?? null,
      test: base.testSha256, image: base.image.digest, node: base.nodeVersion, deps: base.depsSnapshotSha256,
      lock: base.lockfileSha256, env: base.env, seed: base.seed ?? null,
      bc: base.revision.commit, cc: cand.revision.commit, envEqual: effectiveEnvEqual, supported: requirementSupported,
    }),
  );
  return {
    status: 'valid',
    reason: 'attestation verified; hashes bound; outcomes recomputed from signed records',
    candidateId,
    matrix,
    base: base.outcome,
    candidate: cand.outcome,
    baseErrorClass: base.errorClass ?? null,
    candidateErrorClass: cand.errorClass ?? null,
    environmentEqual: effectiveEnvEqual,
    environmentMismatch: mismatch,
    requirementLink: link,
    semanticReview: review,
    requirementSupported,
    requirementReason,
    executionIds: [base.executionId, cand.executionId],
    runId: att.ehRunId ?? null,
    caseId: att.caseId ?? null,
    trust,
    attestationSha256: attF.sha256,
    differentialSha256: diffF.sha256,
    candidateManifestSha256: att.candidateManifestSha256 ?? null,
    specSha256: att.specSha256 ?? null,
    testSha256: base.testSha256,
    targetFile,
    testFile,
    sourceCommit: base.revision.commit,
    candidateCommit: cand.revision.commit,
    reproducer: {
      imageDigest: base.image.digest,
      revision: cand.revision.commit,
      testFile,
      testSha256: base.testSha256,
      argv: Array.isArray(cand.argv) ? cand.argv : [],
      seed: cand.seed ?? null,
    },
    files,
    fingerprint,
  };
}

// ------------------------------------------------------- classification

function mkCheck(kind, status, candidateId, token, expected, actual, hint) {
  const check = {
    kind,
    passed: statusToPassed(status),
    status,
    failed_check_id: `${kind}:${candidateId}:${token}`,
    expected,
    actual,
    diff_hint: hint,
  };
  if (status === 'ERROR') check.error = true;
  if (status === 'PENDING') check.review_required = true;
  if (status === 'UNAVAILABLE') check.unavailable = true;
  return check;
}

function evaluateStability(primary, st) {
  if (!st || !st.performed) return { state: 'not_sampled', reason: 'stability sampling was not performed' };
  if (st.tampered) return { state: 'tampered', reason: st.reason || 'stability evidence does not match the grading manifest' };
  if (!st.bound) return { state: 'unbound', reason: st.reason || 'stability metadata is not bound to the grading manifest' };
  if (!(st.samples >= MIN_STABILITY_SAMPLES)) return { state: 'not_sampled', reason: `only ${st.samples ?? 0} sample(s) configured; ${MIN_STABILITY_SAMPLES} required` };
  const observed = Array.isArray(st.observed) ? st.observed : [];
  if (observed.length < st.samples) return { state: 'incomplete', reason: `${observed.length} of ${st.samples} sampled executions have evidence` };
  if (observed.some((o) => o.evidenceStatus === 'invalid')) return { state: 'invalid_sample', reason: observed.find((o) => o.evidenceStatus === 'invalid').reason || 'sample evidence invalid' };
  if (observed.some((o) => o.evidenceStatus !== 'valid')) return { state: 'incomplete', reason: 'a sample has no authenticated evidence' };
  if (!st.byteIdentical) return { state: 'flaky', reason: 'sample check digests diverged' };
  const fps = new Set(observed.map((o) => o.fingerprint));
  if (fps.size !== 1 || observed.some((o) => o.matrix !== 'PASS->FAIL')) return { state: 'flaky', reason: 'sampled authenticated outcomes diverged' };
  if (observed.some((o) => o.environmentEqual !== true)) return { state: 'incomplete', reason: 'a sample ran under unequal environments' };
  const ids = observed.flatMap((o) => o.executionIds || []);
  if (ids.length !== new Set(ids).size || observed.some((o) => !Array.isArray(o.executionIds) || o.executionIds.length < 2)) return { state: 'reused', reason: 'execution ids are not unique across samples (stale or copied evidence)' };
  if (primary && !observed.some((o) => o.fingerprint === primary.fingerprint)) return { state: 'flaky', reason: 'primary run is absent from sampled outcomes' };
  return { state: 'verified', reason: `${observed.length} identical fresh authenticated executions` };
}

function stageAFor(evidence, env, supported, stabilityState) {
  const rules = [];
  const add = (id, outcome) => rules.push({ id, outcome });
  add('attestation_authenticated', evidence.status === 'valid' ? 'pass' : evidence.status === 'invalid' ? 'reject' : 'downgrade');
  add('differential_recomputed', evidence.status === 'valid' ? 'pass' : 'downgrade');
  add('no_execution_error', evidence.matrix === 'ERROR' ? 'downgrade' : 'pass');
  add('environment_equal', env === true ? 'pass' : 'downgrade');
  add('requirement_supported', supported === true ? 'pass' : 'downgrade');
  add('stability_reproduced', stabilityState === 'verified' ? 'pass' : 'downgrade');
  return { passed: !rules.some((r) => r.outcome === 'reject'), rules };
}

/**
 * Pure classification.
 * input: {
 *   phase: 'score' | 'final',
 *   candidateId, severity,
 *   evidenceStatus: 'valid'|'unavailable'|'invalid', evidenceReason,
 *   base, candidate  ('pass'|'fail'|'error'),
 *   environmentEqual, requirementSupported, requirementLink?, semanticReview?,
 *   stability: { performed, bound, tampered, byteIdentical, samples, observed:[{evidenceStatus,matrix,environmentEqual,executionIds,fingerprint,reason}] } | null,
 *   stageB: { checkId, majority, pass, fail, nulls } | null,   // supporting only
 *   meta: { runId, caseId, evidenceBase, ... }, evidence: summarizeEvidence() result (optional)
 * }
 * returns { classification, matrix, provisional, reproducible, check, stageA, reasons, finding }
 */
function normalizeInput(raw) {
  const ev = raw.evidence;
  if (!ev || typeof ev !== 'object') return raw;
  const derived = {
    candidateId: ev.candidateId,
    evidenceStatus: ev.status,
    evidenceReason: ev.reason,
    base: ev.base,
    candidate: ev.candidate,
    baseErrorClass: ev.baseErrorClass,
    candidateErrorClass: ev.candidateErrorClass,
    environmentEqual: ev.environmentEqual,
    requirementSupported: ev.requirementSupported,
    requirementReason: ev.requirementReason,
    requirementLink: ev.requirementLink,
    semanticReview: ev.semanticReview,
    fingerprint: ev.fingerprint,
  };
  const out = { ...raw };
  for (const [k, v] of Object.entries(derived)) if (out[k] === undefined && v !== undefined) out[k] = v;
  return out;
}

export function classifyDifferential(rawInput) {
  const input = normalizeInput(rawInput);
  const phase = input.phase === 'final' ? 'final' : 'score';
  const candidateId = ID_RE.test(String(input.candidateId ?? '')) ? input.candidateId : 'unknown';
  const severity = SEVERITIES.has(input.severity) ? input.severity : 'medium';
  const evStatus = input.evidenceStatus ?? 'valid';
  const reasons = [];
  const kind = 'discovery_finding';
  const out = (classification, status, token, hint, extra = {}) => {
    const matrix = extra.matrix ?? (evStatus === 'valid' ? computeMatrix(outcomeOf(input.base), outcomeOf(input.candidate)) : null);
    const check = mkCheck(kind, status, candidateId, token, extra.expected ?? 'no regression observed by authenticated differential', extra.actual ?? `${classification ?? 'NO_FINDING'} (${matrix ?? evStatus})`, hint);
    const stabilityState = extra.stabilityState ?? 'n/a';
    const result = {
      classification,
      matrix,
      provisional: extra.provisional === true,
      reproducible: extra.reproducible === true,
      stabilityState,
      check,
      reasons,
      stageA: stageAFor({ status: evStatus, matrix }, input.environmentEqual, input.requirementSupported, stabilityState),
    };
    result.finding = classification === null ? null : buildFinding(input, result, severity, candidateId, evStatus);
    return result;
  };

  // ---- evidence gate
  if (evStatus === 'invalid') {
    reasons.push(input.evidenceReason || 'evidence invalid');
    return out('INCONCLUSIVE', 'ERROR', 'invalid', `INCONCLUSIVE: execution evidence rejected (${input.evidenceReason || 'invalid signature or digest'}); this is a harness error, not a candidate result`, { matrix: null, expected: 'authenticated execution evidence', actual: 'invalid evidence' });
  }
  if (evStatus !== 'valid') {
    reasons.push(input.evidenceReason || 'evidence unavailable');
    return out('INCONCLUSIVE', 'UNAVAILABLE', 'unavailable', `INCONCLUSIVE: authenticated execution evidence unavailable (${input.evidenceReason || 'missing attestation'}); absence is not a pass`, { matrix: null, expected: 'authenticated execution evidence', actual: 'unavailable' });
  }
  const b = outcomeOf(input.base);
  const c = outcomeOf(input.candidate);
  const matrix = computeMatrix(b, c);
  if (matrix === 'ERROR') {
    reasons.push(`execution error (base=${b}, candidate=${c}${input.baseErrorClass || input.candidateErrorClass ? `, class=${input.baseErrorClass || input.candidateErrorClass}` : ''})`);
    return out('INCONCLUSIVE', 'UNAVAILABLE', 'ERROR', `INCONCLUSIVE: an execution ended in error (base=${b}, candidate=${c}); no behavioral conclusion is possible`, { matrix });
  }
  if (input.environmentEqual !== true) {
    reasons.push('base and candidate environments are not identical (image/node/dependencies/env/seed)');
    return out('INCONCLUSIVE', 'UNAVAILABLE', matrix, `INCONCLUSIVE: base and candidate ran under incompatible environments; ${matrix} is not comparable`, { matrix });
  }
  if (matrix === 'PASS->PASS') {
    return out(null, 'PASS', matrix, 'no observed regression for this generated test (not a claim of correctness)', { matrix });
  }
  if (matrix === 'FAIL->PASS') {
    return out('EXPECTED_CHANGE', 'PASS', matrix, 'EXPECTED_CHANGE: test failed on base and passes on candidate (potential fix)', { matrix });
  }
  if (matrix === 'FAIL->FAIL') {
    reasons.push('test fails on base as well; failure is not introduced by the candidate');
    return out('EXISTING_FAILURE', 'PASS', matrix, 'EXISTING_FAILURE: test also fails on base; not attributed to the candidate', { matrix });
  }

  // ---- PASS->FAIL
  const supported = input.requirementSupported === true;
  if (!supported) reasons.push(`requirement not supported (${input.requirementReason || 'unknown'}): an exact quote links the test to the spec but does not prove the assertion matches it`);
  const supportHint = supported ? 'requirement link exact and review-approved' : `requirement support missing (${input.requirementReason || 'no_requirement_ref'})`;

  if (phase === 'score') {
    // Every authenticated, comparable PASS->FAIL is a provisional FAIL so the existing sampling re-runs it; the final
    // phase downgrades unsupported or unreproducible candidates (SUSPECTED / INCONCLUSIVE).
    reasons.push('provisional: reproducibility not yet established; stability sampling decides');
    return out('SUSPECTED_REGRESSION', 'FAIL', matrix, `SUSPECTED_REGRESSION (provisional): PASS->FAIL with equal environments; ${supportHint}; pending stability sampling and final classification`, { matrix, provisional: true });
  }

  const st = evaluateStability({ fingerprint: input.fingerprint }, input.stability);
  const reproducible = st.state === 'verified';
  reasons.push(`stability: ${st.state} (${st.reason})`);
  const extra = { matrix, stabilityState: st.state, reproducible };
  switch (st.state) {
    case 'verified':
      if (supported) {
        return out('VERIFIED_REGRESSION', 'FAIL', matrix, `VERIFIED_REGRESSION: PASS->FAIL reproduced in ${input.stability.observed.length} identical fresh authenticated executions under equal environments; ${supportHint}`, extra);
      }
      return out('SUSPECTED_REGRESSION', 'PENDING', matrix, `SUSPECTED_REGRESSION: reproducible PASS->FAIL but ${supportHint}`, extra);
    case 'not_sampled':
    case 'unbound':
      return out('SUSPECTED_REGRESSION', 'PENDING', matrix, `SUSPECTED_REGRESSION: PASS->FAIL not reproduced (${st.reason}); ${supportHint}`, extra);
    case 'tampered':
    case 'invalid_sample':
      return out('INCONCLUSIVE', 'ERROR', matrix, `INCONCLUSIVE: stability evidence rejected (${st.reason})`, { ...extra, expected: 'authenticated stability evidence', actual: st.state });
    default: // flaky | incomplete | reused
      return out('INCONCLUSIVE', 'UNAVAILABLE', matrix, `INCONCLUSIVE: ${st.state === 'flaky' ? 'nondeterministic result' : 'stability evidence incomplete'} (${st.reason}); no verified regression`, extra);
  }
}

function buildFinding(input, result, severity, candidateId, evStatus) {
  const meta = input.meta || {};
  const ev = input.evidence || {};
  const st = input.stability || null;
  const stBlock = {
    performed: !!(st && st.performed),
    bound: !!(st && st.bound),
    byteIdentical: st ? !!st.byteIdentical : null,
    samples: st && Number.isFinite(st.samples) ? st.samples : 1,
    observedSamples: st && Array.isArray(st.observed) ? st.observed.length : 0,
    executionIds: st && Array.isArray(st.observed) ? st.observed.flatMap((o) => o.executionIds || []) : [],
    state: result.stabilityState,
  };
  const base = outcomeOf(input.base);
  const cand = outcomeOf(input.candidate);
  const attestPath = meta.evidenceBase ? `${meta.evidenceBase}/attestation.json` : 'attestation.json';
  const finding = {
    schema: FINDING_SCHEMA,
    findingId: 'F-' + sha256Hex(canonicalize({ r: meta.runId ?? null, c: meta.caseId ?? null, id: candidateId, t: ev.testSha256 ?? null, b: ev.sourceCommit ?? null, k: ev.candidateCommit ?? null })).slice(0, 16),
    runId: meta.runId ?? null,
    caseId: meta.caseId ?? null,
    candidateId,
    classification: result.classification,
    severity,
    targetFile: ev.targetFile ?? '',
    testFile: ev.testFile ?? '',
    matrix: result.matrix,
    baseResult: evStatus === 'valid' ? base : null,
    candidateResult: evStatus === 'valid' ? cand : null,
    reproducible: result.reproducible,
    finalized: input.phase === 'final',
    evidenceStatus: evStatus,
    environmentEqual: evStatus === 'valid' ? input.environmentEqual === true : null,
    requirementLink: input.requirementLink ?? ev.requirementLink ?? null,
    semanticReview: input.semanticReview ?? ev.semanticReview ?? null,
    requirementSupported: input.requirementSupported === true,
    requirementReason: input.requirementReason ?? ev.requirementReason ?? null,
    evidenceUris: Array.isArray(meta.evidenceUris) ? meta.evidenceUris : [],
    sourceCommit: ev.sourceCommit ?? '',
    candidateCommit: ev.candidateCommit ?? '',
    explanation: result.check.diff_hint,
    reasons: result.reasons,
    reproducer: ev.reproducer ?? { imageDigest: '', revision: '', testFile: '', testSha256: '', argv: [], seed: null },
    filter: { stageA: result.stageA },
    attestation: { path: attestPath, sha256: ev.attestationSha256 ?? null, trust: ev.trust ?? null },
    stability: stBlock,
  };
  if (input.stageB && typeof input.stageB === 'object') {
    finding.filter.stageB = {
      checkId: input.stageB.checkId ?? null,
      majority: input.stageB.majority === 'PASS' || input.stageB.majority === 'FAIL' ? input.stageB.majority : null,
      pass: Number(input.stageB.pass) || 0,
      fail: Number(input.stageB.fail) || 0,
      nulls: Number(input.stageB.nulls) || 0,
    };
  }
  if (input.health) finding.health = input.health;
  if (meta.gradingManifest) finding.gradingManifest = meta.gradingManifest;
  finding.findingSha256 = sha256Hex(canonicalize(finding));
  return finding;
}

/** Optional health check: did the generated test pass on base? Independent of the regression verdict. */
export function classifyTestHealth(input) {
  const candidateId = ID_RE.test(String(input.candidateId ?? '')) ? input.candidateId : 'unknown';
  const kind = 'discovery_test_health';
  const evStatus = input.evidenceStatus ?? 'valid';
  if (evStatus === 'invalid') return { status: 'ERROR', health: null, check: mkCheck(kind, 'ERROR', candidateId, 'invalid', 'authenticated base execution', 'invalid evidence', `test health unavailable: evidence rejected (${input.evidenceReason || 'invalid'})`) };
  if (evStatus !== 'valid') return { status: 'UNAVAILABLE', health: null, check: mkCheck(kind, 'UNAVAILABLE', candidateId, 'unavailable', 'authenticated base execution', 'unavailable', `test health unavailable (${input.evidenceReason || 'missing attestation'})`) };
  const b = outcomeOf(input.base);
  if (b === 'pass') return { status: 'PASS', health: { baseResult: 'pass', healthy: true }, check: mkCheck(kind, 'PASS', candidateId, 'base-pass', 'test passes on base', 'pass', '') };
  if (b === 'fail') return { status: 'FAIL', health: { baseResult: 'fail', healthy: false }, check: mkCheck(kind, 'FAIL', candidateId, 'base-fail', 'test passes on base', 'fail', 'generated test already fails on the base revision (unhealthy test or existing failure)') };
  return { status: 'UNAVAILABLE', health: { baseResult: b ?? 'error', healthy: null }, check: mkCheck(kind, 'UNAVAILABLE', candidateId, 'base-error', 'test passes on base', 'error', `test health unavailable: base execution ended in error${input.baseErrorClass ? ` (${input.baseErrorClass})` : ''}`) };
}

// ------------------------------------------------------------------ CLI

function readInput(file) {
  const raw = file === '-' || !file ? fs.readFileSync(0, 'utf8') : fs.readFileSync(file, 'utf8');
  return JSON.parse(raw);
}

function main(argv) {
  const [cmd, ...rest] = argv;
  const args = Object.fromEntries(rest.filter((a) => a.startsWith('--')).map((a) => { const i = a.indexOf('='); return i < 0 ? [a.slice(2), true] : [a.slice(2, i), a.slice(i + 1)]; }));
  const emit = (v) => process.stdout.write(JSON.stringify(v) + '\n');
  switch (cmd) {
    case 'evidence': emit(summarizeEvidence(readInput(args.input))); return 0;
    case 'classify': emit(classifyDifferential(readInput(args.input))); return 0;
    case 'health': emit(classifyTestHealth(readInput(args.input))); return 0;
    default:
      process.stderr.write('usage: classify.mjs {evidence|classify|health} --input=<file|->\n');
      return 2;
  }
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    process.exitCode = main(process.argv.slice(2));
  } catch (e) {
    process.stderr.write(`classify.mjs: ${e.message}\n`);
    process.exitCode = 1;
  }
}
