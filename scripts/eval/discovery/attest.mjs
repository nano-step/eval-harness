#!/usr/bin/env node
// attest.mjs — signing and verification of atd-sandbox evidence (atd.attestation/v1).
// Dependency-free Node ESM. Signatures use OpenSSH `ssh-keygen -Y sign|verify` (namespace
// atd-execution@v1). Keys live outside every worktree and container mount, by default under
// $EVAL_STATE_DIR/discovery/keys. The trust label is NEVER taken from case/candidate JSON: it comes
// from the trusted environment and is checked against the signer actually used. Verification chooses
// the allowed-signers file from the label inside the signed attestation, so the local key can not
// assert a higher level than local-same-user.
//
// CLI:
//   attest.mjs verify <out-dir>          prints one JSON object; exit 0 valid, 3 unavailable, 1 invalid
//   attest.mjs seal --out-dir=<dir> --attestation=<file>   sign an attestation (trusted callers/tests)
//   attest.mjs ensure-keys               create the local key pair if absent and print its location
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const NAMESPACE = 'atd-execution@v1';
export const PRINCIPAL_PREFIX = 'atd-runner-';
export const TRUST_LEVELS = ['local-same-user', 'separate-user', 'ci-secret'];
export const EXIT_VALID = 0;
export const EXIT_INVALID = 1;
export const EXIT_UNAVAILABLE = 3;

const MAX_JSON_BYTES = 4 * 1024 * 1024;
const MAX_TREE_ENTRIES = 2000;
const SAFE_RECORD_FILE = /^[a-z][a-z0-9_-]{0,31}\.json$/;
const SAFE_ARTIFACT_PATH = /^artifacts\/[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/;
const HEX64 = /^[0-9a-f]{64}$/;

export class AtdError extends Error {
  constructor(code, message) { super(message); this.name = 'AtdError'; this.code = code; }
}

export const sha256Hex = (data) => createHash('sha256').update(data).digest('hex');
export function sha256File(file) {
  const hash = createHash('sha256');
  const fd = fs.openSync(file, 'r');
  try {
    const buf = Buffer.allocUnsafe(1 << 20);
    for (;;) {
      const n = fs.readSync(fd, buf, 0, buf.length, null);
      if (n === 0) break;
      hash.update(buf.subarray(0, n));
    }
  } finally { fs.closeSync(fd); }
  return hash.digest('hex');
}

export function canonicalize(value) {
  if (value === null) return null;
  if (Array.isArray(value)) return value.map((v) => canonicalize(v === undefined ? null : v));
  switch (typeof value) {
    case 'string': case 'boolean': return value;
    case 'number':
      if (!Number.isFinite(value)) throw new AtdError('invalid_number', 'non-finite number in canonical JSON');
      return value;
    case 'object': {
      const out = {};
      for (const key of Object.keys(value).sort()) if (value[key] !== undefined) out[key] = canonicalize(value[key]);
      return out;
    }
    default: throw new AtdError('invalid_value', `unsupported ${typeof value} in canonical JSON`);
  }
}
export const canonicalJson = (value) => `${JSON.stringify(canonicalize(value))}\n`;

// --- state / key management -----------------------------------------------------------------

export function stateDirFrom(env = process.env) {
  return env.EVAL_STATE_DIR || path.join(os.homedir(), '.config', 'opencode', 'eval-harness');
}
const discoveryDir = (stateDir) => path.join(stateDir, 'discovery');
const localKeysDir = (stateDir) => path.join(discoveryDir(stateDir), 'keys');

function cleanEnv() {
  // ssh-keygen must never see an agent socket or other credentials.
  return { PATH: process.env.PATH || '/usr/bin:/bin', LANG: 'C', HOME: process.env.HOME || os.homedir() };
}
function runKeygen(args, opts = {}) {
  return spawnSync('ssh-keygen', args, { env: cleanEnv(), encoding: 'utf8', timeout: 30000, ...opts });
}

function assertPrivateKeyFile(file) {
  const st = fs.lstatSync(file);
  if (!st.isFile()) throw new AtdError('key_invalid', `signing key is not a regular file: ${file}`);
  if ((st.mode & 0o077) !== 0) throw new AtdError('key_invalid', `signing key must not be group/world accessible: ${file}`);
  if (typeof process.getuid === 'function' && st.uid !== process.getuid()) throw new AtdError('key_invalid', `signing key is not owned by the runner user: ${file}`);
}

/** Create the local key pair atomically (temp dir + rename) when absent. Returns paths. */
export function ensureLocalKeys(stateDir) {
  const dir = localKeysDir(stateDir);
  const key = path.join(dir, 'runner_ed25519');
  const allowed = path.join(dir, 'allowed_signers');
  if (!fs.existsSync(key) || !fs.existsSync(`${key}.pub`) || !fs.existsSync(allowed)) {
    fs.mkdirSync(discoveryDir(stateDir), { recursive: true, mode: 0o700 });
    const tmp = fs.mkdtempSync(path.join(discoveryDir(stateDir), '.keygen-'));
    try {
      fs.chmodSync(tmp, 0o700);
      const gen = runKeygen(['-q', '-t', 'ed25519', '-N', '', '-C', 'atd-runner', '-f', path.join(tmp, 'runner_ed25519')]);
      if (gen.status !== 0) throw new AtdError('keygen_failed', `ssh-keygen failed: ${(gen.stderr || '').trim()}`);
      const pub = fs.readFileSync(path.join(tmp, 'runner_ed25519.pub'), 'utf8').trim().split(/\s+/);
      fs.writeFileSync(path.join(tmp, 'allowed_signers'), `${PRINCIPAL_PREFIX}local-same-user namespaces="${NAMESPACE}" ${pub[0]} ${pub[1]}\n`, { mode: 0o600 });
      try { fs.renameSync(tmp, dir); } catch (error) {
        if (!['ENOTEMPTY', 'EEXIST'].includes(error.code)) throw error; // concurrent creator won
      }
    } finally { fs.rmSync(tmp, { recursive: true, force: true }); }
  }
  assertPrivateKeyFile(key);
  return { keyFile: key, allowedSignersFile: allowed, dir };
}

/**
 * Pick the signer from the TRUSTED environment only.
 *   no ATD_SIGNING_KEY_FILE            -> local key, trust local-same-user (ATD_TRUST must be unset/local)
 *   ATD_SIGNING_KEY_FILE + ALLOWED     -> external key, trust = ATD_TRUST (default local-same-user)
 */
export function resolveSigner({ stateDir = stateDirFrom(), env = process.env, forbiddenRoots = [] } = {}) {
  const trust = env.ATD_TRUST || 'local-same-user';
  if (!TRUST_LEVELS.includes(trust)) throw new AtdError('trust_invalid', `ATD_TRUST must be one of ${TRUST_LEVELS.join(', ')}`);
  let signer;
  if (env.ATD_SIGNING_KEY_FILE) {
    if (!env.ATD_ALLOWED_SIGNERS_FILE) throw new AtdError('key_invalid', 'ATD_SIGNING_KEY_FILE requires ATD_ALLOWED_SIGNERS_FILE');
    for (const f of [env.ATD_SIGNING_KEY_FILE, env.ATD_ALLOWED_SIGNERS_FILE]) if (!path.isAbsolute(f)) throw new AtdError('key_invalid', 'external key paths must be absolute');
    assertPrivateKeyFile(env.ATD_SIGNING_KEY_FILE);
    signer = { keyFile: env.ATD_SIGNING_KEY_FILE, allowedSignersFile: env.ATD_ALLOWED_SIGNERS_FILE, source: 'external' };
  } else {
    if (trust !== 'local-same-user') throw new AtdError('trust_invalid', `trust ${trust} requires an external signing key (ATD_SIGNING_KEY_FILE); the local key only supports local-same-user`);
    const keys = ensureLocalKeys(stateDir);
    signer = { keyFile: keys.keyFile, allowedSignersFile: keys.allowedSignersFile, source: 'local' };
  }
  const real = (p) => { try { return fs.realpathSync(p); } catch { return path.resolve(p); } };
  for (const root of forbiddenRoots) {
    const r = real(root);
    for (const f of [signer.keyFile, signer.allowedSignersFile]) {
      const rf = real(f);
      if (rf === r || rf.startsWith(r + path.sep)) throw new AtdError('key_invalid', `signing material must live outside ${root}`);
    }
  }
  return { ...signer, trust, principal: `${PRINCIPAL_PREFIX}${trust}` };
}

function verifyWithKeygen(allowedSignersFile, principal, sigFile, bytes) {
  return runKeygen(['-Y', 'verify', '-f', allowedSignersFile, '-I', principal, '-n', NAMESPACE, '-s', sigFile], { input: bytes });
}

/** Write attestation.json (canonical) + attestation.json.sig in outDir. */
export function sealAttestation(outDir, attestation, signer) {
  const attFile = path.join(outDir, 'attestation.json');
  const sigFile = `${attFile}.sig`;
  fs.rmSync(sigFile, { force: true });
  if (attestation.trust !== signer.trust) throw new AtdError('trust_invalid', 'attestation trust label does not match the signer');
  fs.writeFileSync(attFile, canonicalJson(attestation), { mode: 0o644 });
  const res = runKeygen(['-Y', 'sign', '-q', '-f', signer.keyFile, '-n', NAMESPACE, attFile]);
  if (res.status !== 0 || !fs.existsSync(sigFile)) throw new AtdError('sign_failed', `ssh-keygen sign failed: ${(res.stderr || '').trim()}`);
  // Self-check: never emit evidence the verifier would reject.
  const check = verifyWithKeygen(signer.allowedSignersFile, signer.principal, sigFile, fs.readFileSync(attFile));
  if (check.status !== 0) throw new AtdError('sign_failed', 'freshly produced signature does not verify against the allowed signers');
  return { attestationSha256: sha256File(attFile) };
}

// --- verification ---------------------------------------------------------------------------

function result(status, reason, extra = {}) {
  return { status, reason, trust: null, attestationSha256: null, executionIds: [], ...extra };
}
const invalid = (reason, extra) => result('invalid', reason, extra);

function walkOutDir(outDir) {
  const files = [];
  const stack = [''];
  while (stack.length) {
    const rel = stack.pop();
    const dir = path.join(outDir, rel);
    for (const name of fs.readdirSync(dir)) {
      const relPath = rel ? `${rel}/${name}` : name;
      const st = fs.lstatSync(path.join(dir, name));
      if (st.isSymbolicLink()) return { error: `symlink in evidence directory: ${relPath}` };
      if (st.isDirectory()) { stack.push(relPath); continue; }
      if (!st.isFile()) return { error: `special file in evidence directory: ${relPath}` };
      files.push(relPath);
      if (files.length > MAX_TREE_ENTRIES) return { error: 'evidence directory has too many entries' };
    }
  }
  return { files };
}

function readJsonBytes(file) {
  const st = fs.lstatSync(file);
  if (!st.isFile()) throw new AtdError('not_file', `${file} is not a regular file`);
  if (st.size > MAX_JSON_BYTES) throw new AtdError('too_large', `${file} exceeds ${MAX_JSON_BYTES} bytes`);
  return fs.readFileSync(file);
}

export function verifyOutDir(outDir, { stateDir = stateDirFrom(), env = process.env } = {}) {
  let st;
  try { st = fs.lstatSync(outDir); } catch { return result('unavailable', 'out-dir missing'); }
  if (st.isSymbolicLink() || !st.isDirectory()) return invalid('out-dir is not a plain directory');
  const attFile = path.join(outDir, 'attestation.json');
  const sigFile = `${attFile}.sig`;
  const lst = (f) => { try { return fs.lstatSync(f); } catch { return null; } };
  const attSt = lst(attFile); const sigSt = lst(sigFile);
  if (!attSt || !sigSt) return result('unavailable', !attSt ? 'attestation.json absent' : 'attestation.json.sig absent');
  if (!attSt.isFile() || !sigSt.isFile()) return invalid('attestation or signature is not a regular file');

  const tree = (() => { try { return walkOutDir(outDir); } catch (e) { return { error: `evidence directory unreadable: ${e.message}` }; } })();
  if (tree.error) return invalid(tree.error);

  let attBytes;
  try { attBytes = readJsonBytes(attFile); } catch (e) { return invalid(`attestation unreadable: ${e.message}`); }
  let att;
  try { att = JSON.parse(attBytes.toString('utf8')); } catch { return invalid('attestation.json is not valid JSON'); }
  if (!att || typeof att !== 'object' || att.schema !== 'atd.attestation/v1') return invalid('attestation schema is not atd.attestation/v1');
  if (!TRUST_LEVELS.includes(att.trust)) return invalid('attestation trust label is unknown');
  const attestationSha256 = sha256Hex(attBytes);
  const base = { trust: att.trust, attestationSha256 };

  // Signature first: nothing inside the attestation is believed before it verifies.
  const principal = `${PRINCIPAL_PREFIX}${att.trust}`;
  let allowedFiles;
  if (att.trust === 'local-same-user') {
    allowedFiles = [path.join(localKeysDir(stateDir), 'allowed_signers')];
    if (env.ATD_ALLOWED_SIGNERS_FILE) allowedFiles.push(env.ATD_ALLOWED_SIGNERS_FILE);
  } else {
    if (!env.ATD_ALLOWED_SIGNERS_FILE) return invalid(`no external allowed-signers configured for trust ${att.trust}`, base);
    const localAllowed = path.join(localKeysDir(stateDir), 'allowed_signers');
    try {
      if (fs.existsSync(localAllowed) && fs.realpathSync(localAllowed) === fs.realpathSync(env.ATD_ALLOWED_SIGNERS_FILE)) {
        return invalid(`trust ${att.trust} may not be verified against the local key`, base);
      }
    } catch { /* fall through to the verify below */ }
    allowedFiles = [env.ATD_ALLOWED_SIGNERS_FILE];
  }
  let signatureOk = false; let sawKey = false;
  for (const allowed of allowedFiles) {
    if (!fs.existsSync(allowed)) continue;
    sawKey = true;
    const res = verifyWithKeygen(allowed, principal, sigFile, attBytes);
    if (res.status === 0) { signatureOk = true; break; }
  }
  if (!sawKey) return invalid('no allowed-signers file is available for this trust level (unknown signer)', base);
  if (!signatureOk) return invalid('signature verification failed (bad signature or unknown signer)', base);

  // Structure and hash binding.
  if (!Array.isArray(att.executions) || att.executions.length === 0) return invalid('attestation lists no executions', base);
  if (!Array.isArray(att.artifacts)) return invalid('attestation.artifacts missing', base);
  const allowedFilesSet = new Set(['attestation.json', 'attestation.json.sig']);
  const read = (rel) => {
    const abs = path.join(outDir, rel);
    const real = fs.realpathSync(abs);
    const root = fs.realpathSync(outDir);
    if (!real.startsWith(root + path.sep)) throw new AtdError('escape', `${rel} escapes the evidence directory`);
    return readJsonBytes(abs);
  };
  const artifactIndex = new Map();
  for (const art of att.artifacts) {
    if (!art || typeof art.path !== 'string' || !SAFE_ARTIFACT_PATH.test(art.path) || !HEX64.test(art.sha256 || '')) return invalid('attestation lists a malformed artifact', base);
    if (artifactIndex.has(art.path)) return invalid('attestation lists a duplicate artifact path', base);
    artifactIndex.set(art.path, art.sha256);
    allowedFilesSet.add(art.path);
    if (!tree.files.includes(art.path)) return invalid(`artifact missing: ${art.path}`, base);
    if (sha256File(path.join(outDir, art.path)) !== art.sha256) return invalid(`artifact digest mismatch: ${art.path}`, base);
  }
  const executionIds = [];
  const records = [];
  for (const ex of att.executions) {
    if (!ex || typeof ex.recordFile !== 'string' || !SAFE_RECORD_FILE.test(ex.recordFile) || !HEX64.test(ex.recordSha256 || '') || typeof ex.executionId !== 'string') return invalid('attestation lists a malformed execution', base);
    allowedFilesSet.add(ex.recordFile);
    if (!tree.files.includes(ex.recordFile)) return invalid(`record missing: ${ex.recordFile}`, base);
    let bytes;
    try { bytes = read(ex.recordFile); } catch (e) { return invalid(`record unreadable: ${e.message}`, base); }
    if (sha256Hex(bytes) !== ex.recordSha256) return invalid(`record digest mismatch: ${ex.recordFile}`, base);
    let rec;
    try { rec = JSON.parse(bytes.toString('utf8')); } catch { return invalid(`record is not JSON: ${ex.recordFile}`, base); }
    if (rec.schema !== 'atd.execution-record/v1' || rec.executionId !== ex.executionId) return invalid(`record identity mismatch: ${ex.recordFile}`, base);
    if (rec.candidateId !== att.candidateId) return invalid(`record candidateId differs from attestation: ${ex.recordFile}`, base);
    if (rec.testSha256 !== att.testSha256) return invalid(`record testSha256 differs from attestation: ${ex.recordFile}`, base);
    if (ex.side !== undefined && rec.side !== ex.side) return invalid(`record side mismatch: ${ex.recordFile}`, base);
    for (const art of rec.artifacts || []) {
      if (!art || artifactIndex.get(art.path) !== art.sha256) return invalid(`record artifact ${art && art.path} is not covered by the attestation`, base);
    }
    executionIds.push(ex.executionId);
    records.push(rec);
  }
  if (new Set(executionIds).size !== executionIds.length) return invalid('duplicate execution ids', { ...base, executionIds });
  const out = { ...base, executionIds };
  let diff = null;
  if (att.differentialSha256 !== undefined && att.differentialSha256 !== null) {
    if (!HEX64.test(att.differentialSha256)) return invalid('differentialSha256 malformed', out);
    allowedFilesSet.add('differential.json');
    if (!tree.files.includes('differential.json')) return invalid('differential.json missing', out);
    let bytes;
    try { bytes = read('differential.json'); } catch (e) { return invalid(`differential unreadable: ${e.message}`, out); }
    if (sha256Hex(bytes) !== att.differentialSha256) return invalid('differential digest mismatch', out);
    try { diff = JSON.parse(bytes.toString('utf8')); } catch { return invalid('differential.json is not JSON', out); }
    if (diff.schema !== 'atd.differential/v1' || diff.candidateId !== att.candidateId) return invalid('differential identity mismatch', out);
    const sides = new Map(records.map((r) => [r.side, r.executionId]));
    if (sides.get('base') !== diff.base || sides.get('candidate') !== diff.candidate) return invalid('differential does not reference the attested executions', out);
  }
  for (const file of tree.files) if (!allowedFilesSet.has(file)) return invalid(`unattested file in evidence directory: ${file}`, out);
  return {
    status: 'valid', reason: 'signature and every referenced digest verified',
    trust: att.trust, attestationSha256, executionIds,
    candidateId: att.candidateId, testSha256: att.testSha256, specSha256: att.specSha256 ?? null,
    candidateManifestSha256: att.candidateManifestSha256 ?? null,
    differentialSha256: att.differentialSha256 ?? null,
    matrix: diff ? diff.matrix : null, environmentEqual: diff ? diff.environmentEqual : null,
    ehRunId: att.ehRunId ?? null, caseId: att.caseId ?? null,
  };
}

export const exitCodeFor = (res) => (res.status === 'valid' ? EXIT_VALID : res.status === 'unavailable' ? EXIT_UNAVAILABLE : EXIT_INVALID);

// --- CLI ------------------------------------------------------------------------------------

function cli(argv) {
  const [cmd, ...rest] = argv;
  if (cmd === 'verify') {
    if (!rest[0]) { console.error('usage: attest.mjs verify <out-dir>'); return 2; }
    let res;
    try { res = verifyOutDir(rest[0]); } catch (error) { res = invalid(`verifier error: ${error.message}`); }
    process.stdout.write(`${JSON.stringify(res)}\n`);
    return exitCodeFor(res);
  }
  if (cmd === 'seal') {
    const arg = (name) => (rest.find((a) => a.startsWith(`--${name}=`)) || '').slice(name.length + 3);
    const outDir = arg('out-dir'); const attFile = arg('attestation');
    if (!outDir || !attFile) { console.error('usage: attest.mjs seal --out-dir=<dir> --attestation=<file>'); return 2; }
    try {
      const attestation = JSON.parse(fs.readFileSync(attFile, 'utf8'));
      const signer = resolveSigner({ forbiddenRoots: [outDir] });
      attestation.trust = signer.trust;
      const res = sealAttestation(outDir, attestation, signer);
      process.stdout.write(`${JSON.stringify({ ok: true, trust: signer.trust, ...res })}\n`);
      return 0;
    } catch (error) { console.error(`attest: ${error.message}`); return 13; }
  }
  if (cmd === 'ensure-keys') {
    try { process.stdout.write(`${JSON.stringify(ensureLocalKeys(stateDirFrom()))}\n`); return 0; } catch (error) { console.error(`attest: ${error.message}`); return 13; }
  }
  console.error('usage: attest.mjs verify <out-dir> | seal --out-dir= --attestation= | ensure-keys');
  return 2;
}

const isMain = (() => { try { return Boolean(process.argv[1]) && fs.realpathSync(process.argv[1]) === fs.realpathSync(fileURLToPath(import.meta.url)); } catch { return false; } })();
if (isMain) process.exitCode = cli(process.argv.slice(2));
