#!/usr/bin/env node
// sandbox.mjs — atd-sandbox controller. Runs generated tests against a base and a candidate
// revision inside a fail-closed Docker confinement profile and publishes signed evidence.
//
//   sandbox.mjs run --workdir=<dir> [--transcript=<file>]     runner_config JSON on stdin
//   sandbox.mjs preflight [--quick] [--dependencies=<dir>]     verify Docker/image/confinement
//   sandbox.mjs fingerprint                                    runner+policy identity hash
//   sandbox.mjs teardown --workdir=<dir>                       remove leftover containers
//   sandbox.mjs mutation --repository= --commit= --dependencies= --config= --out= [...]
//
// Security stance: every failure that prevents a trustworthy execution (missing daemon, image,
// unexpected confinement, bad input, path violation) exits 13 and publishes NOTHING. There is no host
// fallback: test code only ever runs inside the container. Container output, reporter files and the
// workdir are untrusted data; they are size-bounded, hashed and never interpolated into a shell.
import { createHash, randomUUID } from 'node:crypto';
import { spawn, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  AtdError, canonicalJson, resolveSigner, sealAttestation, sha256File, sha256Hex, stateDirFrom,
} from './attest.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const CONTAINER_DIR = path.join(HERE, 'sandbox-container');
const DEFAULT_POLICY = path.join(HERE, 'policy', 'atd-sandbox.v1.json');
const RUNNER_SCRIPT = path.join(HERE, '..', 'runners', 'atd-sandbox.sh');
export const EXIT_INFRA = 13;

const SHA1_RE = /^[0-9a-f]{40}$/;
const HEX64 = /^[0-9a-f]{64}$/;
const CASE_ID_RE = /^[A-Za-z0-9][A-Za-z0-9._-]*$/;
const REL_PATH_RE = /^[A-Za-z0-9._@+-]+(\/[A-Za-z0-9._@+-]+)*$/;
const MOUNT_PATH_RE = /^[A-Za-z0-9_@%+=:./~ -]+$/;
const CONFIG_KEYS = new Set(['repository', 'baseCommit', 'candidateCommit', 'candidateFile', 'testsDir', 'testsRel', 'specFile', 'dependencies', 'image', 'seed', 'timeoutSeconds']);

const fail = (code, message) => { throw new AtdError(code, message); };
const sha = (d) => sha256Hex(d);

// --- policy ----------------------------------------------------------------------------------

export function loadPolicy(env = process.env) {
  const file = env.EVAL_ATD_POLICY || DEFAULT_POLICY;
  let bytes;
  try { bytes = fs.readFileSync(file); } catch (e) { fail('policy_unreadable', `cannot read policy ${file}: ${e.message}`); }
  let p;
  try { p = JSON.parse(bytes.toString('utf8')); } catch { fail('policy_invalid', `policy ${file} is not JSON`); }
  const need = (cond, what) => { if (!cond) fail('policy_invalid', `policy ${file}: ${what}`); };
  need(p && p.schema === 'atd.sandbox-policy/v1' && p.id === 'atd-sandbox/v1', 'schema/id');
  need(p.image && /^[a-z0-9._/-]+@sha256:[0-9a-f]{64}$/.test(p.image.ref) && p.image.digest === p.image.ref.slice(p.image.ref.indexOf('@') + 1), 'image must be a digest-pinned ref');
  need(Array.isArray(p.allowedImages) && p.allowedImages.includes(p.image.ref), 'allowedImages must contain the default image');
  need(/^[0-9]+:[0-9]+$/.test(p.user) && !p.user.startsWith('0:') && !p.user.endsWith(':0'), 'user must be a non-root uid:gid');
  need(p.trust && p.trust.default === 'local-same-user', 'default trust must be local-same-user');
  const l = p.limits || {};
  for (const k of ['pidsLimit', 'memoryBytes', 'cpus', 'tmpMegabytes', 'fileSizeBytes', 'openFiles', 'defaultTimeoutSeconds', 'maxTimeoutSeconds', 'maxExportFiles', 'maxExportBytes', 'maxTestFiles', 'maxTestBytes', 'maxReporterBytes', 'maxLogBytes', 'maxCandidateBytes', 'maxSpecBytes', 'maxDependencyFiles', 'maxMutationSeconds', 'mutationWorkMegabytes', 'defaultMaxMutants', 'hardMaxMutants']) {
    need(Number.isFinite(l[k]) && l[k] > 0, `limits.${k}`);
  }
  need(l.defaultTimeoutSeconds <= l.maxTimeoutSeconds, 'default timeout exceeds max');
  need(Number.isSafeInteger(l.defaultMaxMutants) && Number.isSafeInteger(l.hardMaxMutants) && l.defaultMaxMutants >= 1 && l.defaultMaxMutants <= l.hardMaxMutants, 'limits.defaultMaxMutants/hardMaxMutants');
  need(p.env && p.env.static && Array.isArray(p.env.seeded) && Array.isArray(p.env.imageDefaults), 'env allowlist');
  return { policy: p, policySha256: sha(bytes), policyFile: file };
}

// --- config ----------------------------------------------------------------------------------

function safeRel(value, what) {
  if (typeof value !== 'string' || !REL_PATH_RE.test(value) || value.split('/').some((s) => s === '.' || s === '..' || s === '.git')) fail('config_invalid', `${what} must be a safe relative path`);
  return value;
}
function realDir(p, what) {
  try { const r = fs.realpathSync(p); if (!fs.statSync(r).isDirectory()) throw new Error('not a directory'); return r; } catch (e) { fail('config_invalid', `${what} is not an existing directory: ${e.message}`); }
  return null;
}
function mountSafe(p, what) {
  if (!MOUNT_PATH_RE.test(p)) fail('config_invalid', `${what} contains characters that are not allowed in a mount path`);
  return p;
}

export function validateConfig(raw, policyBundle, workdirInput) {
  const { policy } = policyBundle;
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) fail('config_invalid', 'runner_config must be an object');
  for (const key of Object.keys(raw)) if (!CONFIG_KEYS.has(key)) fail('config_invalid', `unknown runner_config key '${key}'`);
  if (!path.isAbsolute(workdirInput || '')) fail('config_invalid', 'workdir must be absolute');
  const workdir = realDir(workdirInput, 'workdir');
  if (typeof raw.repository !== 'string' || !path.isAbsolute(raw.repository)) fail('config_invalid', 'repository must be an absolute path');
  const repository = realDir(raw.repository, 'repository');
  for (const k of ['baseCommit', 'candidateCommit']) if (typeof raw[k] !== 'string' || !SHA1_RE.test(raw[k])) fail('config_invalid', `${k} must be a full 40-hex commit SHA`);
  const cfg = {
    workdir, repository,
    baseCommit: raw.baseCommit, candidateCommit: raw.candidateCommit,
    candidateFile: safeRel(raw.candidateFile ?? 'candidate.json', 'candidateFile'),
    testsDir: safeRel(raw.testsDir ?? 'tests', 'testsDir'), // HOST input root inside the workdir (generated tests live here)
    testsRel: raw.testsRel === undefined || raw.testsRel === '.' ? '.' : safeRel(raw.testsRel, 'testsRel'), // revision-relative PLACEMENT root
    specFile: safeRel(raw.specFile ?? 'SPEC.md', 'specFile'),
    image: policy.image.ref, seed: 1, timeoutSeconds: policy.limits.defaultTimeoutSeconds, dependencies: null,
  };
  if (cfg.testsRel !== '.' && cfg.testsRel.split('/').some((s) => s === 'node_modules')) fail('config_invalid', `testsRel ${cfg.testsRel} uses a reserved path segment`);
  if (raw.image !== undefined) {
    if (typeof raw.image !== 'string' || !policy.allowedImages.includes(raw.image)) fail('config_invalid', 'image is not a digest-pinned image allowed by the trusted policy');
    cfg.image = raw.image;
  }
  if (raw.seed !== undefined) {
    if (!Number.isSafeInteger(raw.seed) || raw.seed < 0) fail('config_invalid', 'seed must be a non-negative integer');
    cfg.seed = raw.seed;
  }
  if (raw.timeoutSeconds !== undefined) {
    if (!Number.isFinite(raw.timeoutSeconds) || raw.timeoutSeconds <= 0 || raw.timeoutSeconds > policy.limits.maxTimeoutSeconds) fail('config_invalid', `timeoutSeconds must be in (0, ${policy.limits.maxTimeoutSeconds}]`);
    cfg.timeoutSeconds = raw.timeoutSeconds;
  }
  if (raw.dependencies !== undefined && raw.dependencies !== null) {
    if (typeof raw.dependencies !== 'string' || !path.isAbsolute(raw.dependencies)) fail('config_invalid', 'dependencies must be an absolute path');
    cfg.dependencies = realDir(raw.dependencies, 'dependencies');
    if (cfg.dependencies === workdir || cfg.dependencies.startsWith(workdir + path.sep) || workdir.startsWith(cfg.dependencies + path.sep)) fail('config_invalid', 'dependencies must live outside the case workdir (generator-writable)');
    const rel = (f) => path.join(cfg.dependencies, f);
    for (const [f, want] of [['node_modules', 'dir'], ['package-lock.json', 'file']]) {
      let st; try { st = fs.lstatSync(rel(f)); } catch { fail('config_invalid', `dependency snapshot lacks ${f}`); }
      if (st.isSymbolicLink() || (want === 'dir' ? !st.isDirectory() : !st.isFile())) fail('config_invalid', `dependency snapshot ${f} must be a plain ${want}`);
    }
    mountSafe(rel('node_modules'), 'dependencies'); mountSafe(rel('package-lock.json'), 'dependencies');
  }
  return cfg;
}

function resolveInside(root, rel, what, { expect }) {
  let cur = root;
  for (const seg of rel.split('/')) {
    cur = path.join(cur, seg);
    let st;
    try { st = fs.lstatSync(cur); } catch { return null; }
    if (st.isSymbolicLink()) fail('path_violation', `${what} traverses a symlink`);
  }
  const st = fs.lstatSync(cur);
  if (expect === 'file' && !st.isFile()) fail('path_violation', `${what} is not a regular file`);
  if (expect === 'dir' && !st.isDirectory()) fail('path_violation', `${what} is not a directory`);
  const real = fs.realpathSync(cur);
  if (real !== root && !real.startsWith(root + path.sep)) fail('path_violation', `${what} escapes the workdir`);
  return cur;
}

function readBounded(file, max, what) {
  const st = fs.lstatSync(file);
  if (!st.isFile()) fail('path_violation', `${what} is not a regular file`);
  if (st.size > max) fail('input_too_large', `${what} exceeds ${max} bytes`);
  return fs.readFileSync(file);
}

// --- candidate, tests, spec ------------------------------------------------------------------

export function loadInputs(cfg, policy) {
  const { workdir } = cfg;
  const candPath = resolveInside(workdir, cfg.candidateFile, 'candidateFile', { expect: 'file' });
  if (!candPath) fail('input_missing', `candidate manifest not found at ${cfg.candidateFile}`);
  const candBytes = readBounded(candPath, policy.limits.maxCandidateBytes, 'candidate manifest');
  let cand;
  try { cand = JSON.parse(candBytes.toString('utf8')); } catch { fail('candidate_invalid', 'candidate manifest is not JSON'); }
  const need = (c, m) => { if (!c) fail('candidate_invalid', m); };
  need(cand && cand.schema === 'atd.test-candidate/v1', 'schema must be atd.test-candidate/v1');
  need(typeof cand.id === 'string' && CASE_ID_RE.test(cand.id), 'id must match the case-id rule');
  need(cand.trust === 'untrusted', 'candidate trust must be "untrusted"');
  need(['node:test', 'vitest'].includes(cand.framework), 'framework must be node:test or vitest');
  need(typeof cand.testFile === 'string', 'testFile missing');
  safeRel(cand.testFile, 'candidate.testFile');
  need(typeof cand.testSha256 === 'string' && HEX64.test(cand.testSha256), 'testSha256 must be hex sha256');
  if (cand.provenance) {
    if (cand.provenance.baseCommit !== undefined) need(cand.provenance.baseCommit === cfg.baseCommit, 'provenance.baseCommit differs from runner_config.baseCommit');
    if (cand.provenance.candidateCommit !== undefined) need(cand.provenance.candidateCommit === cfg.candidateCommit, 'provenance.candidateCommit differs from runner_config.candidateCommit');
  }
  const fwPolicy = policy.frameworks[cand.framework];
  need(fwPolicy.extensions.includes(path.extname(cand.testFile)), `test file extension is not allowed for ${cand.framework}`);

  // Tests: regular files only, bounded, no symlinks (a symlink would leak host files into the container).
  const testsRoot = resolveInside(workdir, cfg.testsDir, 'testsDir', { expect: 'dir' });
  if (!testsRoot) fail('input_missing', `tests directory not found at ${cfg.testsDir}`);
  const files = [];
  let total = 0;
  const walk = (dirAbs, rel) => {
    for (const name of fs.readdirSync(dirAbs).sort()) {
      const abs = path.join(dirAbs, name);
      const relPath = rel ? `${rel}/${name}` : name;
      const st = fs.lstatSync(abs);
      if (st.isSymbolicLink()) fail('path_violation', `symlink in tests directory: ${relPath}`);
      if (st.isDirectory()) { walk(abs, relPath); continue; }
      if (!st.isFile()) fail('path_violation', `non-regular file in tests directory: ${relPath}`);
      if (!REL_PATH_RE.test(relPath)) fail('path_violation', `unsafe test path: ${relPath}`);
      total += st.size;
      if (files.length + 1 > policy.limits.maxTestFiles || total > policy.limits.maxTestBytes) fail('input_too_large', 'tests directory exceeds the policy bounds');
      files.push({ rel: relPath, bytes: fs.readFileSync(abs) });
    }
  };
  walk(testsRoot, '');
  const testEntry = files.find((f) => f.rel === cand.testFile);
  if (!testEntry) fail('input_missing', `candidate.testFile ${cand.testFile} is not present in ${cfg.testsDir}`);
  const testSha256 = sha(testEntry.bytes);
  if (testSha256 !== cand.testSha256) fail('candidate_invalid', 'candidate.testSha256 does not match the test file bytes');
  const testsTreeSha256 = sha(files.map((f) => `${f.rel}\0${sha(f.bytes)}\0`).join(''));

  let specSha256 = null;
  const specPath = resolveInside(workdir, cfg.specFile, 'specFile', { expect: 'file' });
  if (specPath) specSha256 = sha(readBounded(specPath, policy.limits.maxSpecBytes, 'spec file'));

  return { cand, candidateManifestSha256: sha(candBytes), files, testSha256, testsTreeSha256, specSha256, testFile: cand.testFile, framework: cand.framework };
}

// --- git export -------------------------------------------------------------------------------

function gitEnv() {
  return { PATH: process.env.PATH || '/usr/bin:/bin', HOME: process.env.HOME || os.homedir(), GIT_TERMINAL_PROMPT: '0', GIT_CONFIG_NOSYSTEM: '1', GIT_OPTIONAL_LOCKS: '0', LANG: 'C' };
}
function git(repo, args, opts = {}) {
  const res = spawnSync('git', ['-C', repo, '-c', 'core.fsmonitor=false', '-c', 'core.hooksPath=/dev/null', ...args], { env: gitEnv(), maxBuffer: 512 * 1024 * 1024, timeout: 120000, ...opts });
  if (res.error || res.status !== 0) fail('git_failed', `git ${args[0]} failed: ${(res.stderr || res.error || '').toString().trim().slice(0, 300)}`);
  return res.stdout;
}

export function assertCommit(repo, sha1) {
  const res = spawnSync('git', ['-C', repo, 'cat-file', '-e', `${sha1}^{commit}`], { env: gitEnv(), timeout: 30000 });
  if (res.status !== 0) fail('config_invalid', `commit ${sha1} does not exist in the repository`);
}

async function exportRevision(repo, commit, dest, policy) {
  const listing = git(repo, ['ls-tree', '-r', '-z', '--full-tree', commit]).toString('utf8');
  const entries = [];
  for (const rec of listing.split('\0')) {
    if (!rec) continue;
    const tab = rec.indexOf('\t');
    const [mode, type, oid] = rec.slice(0, tab).split(' ');
    const rel = rec.slice(tab + 1);
    const segs = rel.split('/');
    if (!rel || rel.startsWith('/') || rel.includes('\\') || /[\0-\x1f]/.test(rel) || segs.some((s) => s === '' || s === '.' || s === '..' || s.toLowerCase() === '.git')) fail('export_invalid', `unsafe path in revision ${commit}: ${JSON.stringify(rel)}`);
    if (mode === '160000' || type === 'commit') fail('export_invalid', `revision ${commit} contains a submodule at ${rel}`);
    if (!['100644', '100755', '120000'].includes(mode) || type !== 'blob') fail('export_invalid', `unsupported tree entry ${mode} ${type} at ${rel}`);
    entries.push({ mode, oid, rel });
  }
  if (entries.length > policy.limits.maxExportFiles) fail('export_invalid', 'revision exceeds the export file limit');
  fs.mkdirSync(dest, { recursive: true, mode: 0o755 });
  const hashLines = [];
  const links = [];
  let bytesTotal = 0;
  await new Promise((resolve, reject) => {
    const child = spawn('git', ['-C', repo, 'cat-file', '--batch'], { env: gitEnv(), stdio: ['pipe', 'pipe', 'pipe'] });
    let buf = Buffer.alloc(0); let index = 0; let settled = false; let stderr = '';
    const done = (err) => { if (!settled) { settled = true; err ? reject(err) : resolve(); } };
    child.stderr.on('data', (c) => { stderr += c.toString(); });
    child.on('error', done);
    const pump = () => {
      while (index < entries.length) {
        const nl = buf.indexOf(0x0a);
        if (nl < 0) return;
        const header = buf.subarray(0, nl).toString('utf8').split(' ');
        const entry = entries[index];
        if (header[1] !== 'blob' || header[0] !== entry.oid) { child.kill('SIGKILL'); return done(new AtdError('export_invalid', `git returned an unexpected object for ${entry.rel}`)); }
        const size = Number(header[2]);
        if (!Number.isSafeInteger(size)) { child.kill('SIGKILL'); return done(new AtdError('export_invalid', 'bad blob size')); }
        if (size < 0 || size > policy.limits.maxExportBytes - bytesTotal) { child.kill('SIGKILL'); return done(new AtdError('export_invalid', `blob for ${entry.rel} exceeds the remaining export byte limit`)); }
        if (buf.length < nl + 1 + size + 1) return;
        const content = buf.subarray(nl + 1, nl + 1 + size);
        bytesTotal += size;
        if (bytesTotal > policy.limits.maxExportBytes) { child.kill('SIGKILL'); return done(new AtdError('export_invalid', 'revision exceeds the export byte limit')); }
        try {
          if (entry.mode === '120000') {
            const target = content.toString('utf8');
            if (!target || target.includes('\0') || target.length > 4096) throw new AtdError('export_invalid', `unsafe symlink target at ${entry.rel}`);
            links.push({ rel: entry.rel, target });
            hashLines.push(`l\0${entry.rel}\0${target}\0`);
          } else {
            const abs = path.join(dest, ...entry.rel.split('/'));
            fs.mkdirSync(path.dirname(abs), { recursive: true, mode: 0o755 });
            fs.writeFileSync(abs, content, { flag: 'wx', mode: entry.mode === '100755' ? 0o755 : 0o644 });
            fs.chmodSync(abs, entry.mode === '100755' ? 0o755 : 0o644);
            hashLines.push(`f\0${entry.mode}\0${entry.rel}\0${sha(content)}\0`);
          }
        } catch (e) { child.kill('SIGKILL'); return done(e); }
        buf = buf.subarray(nl + 1 + size + 1);
        index += 1;
      }
      child.stdin.end();
    };
    child.stdout.on('data', (chunk) => { buf = buf.length ? Buffer.concat([buf, chunk]) : chunk; pump(); });
    child.on('close', (code) => { if (index !== entries.length) done(new AtdError('export_invalid', `git cat-file ended early (${index}/${entries.length}): ${stderr.slice(0, 200)}`)); else if (code !== 0) done(new AtdError('export_invalid', 'git cat-file failed')); else done(); });
    child.stdin.write(entries.map((e) => `${e.oid}\n`).join(''));
    if (entries.length === 0) child.stdin.end();
  });
  for (const link of links) { // after files: never traversed on the host; parents are real directories only
    const segs = link.rel.split('/');
    const parent = ensureRealDirs(dest, segs.slice(0, -1), `symlink ${link.rel}`);
    fs.symlinkSync(link.target, path.join(parent, segs[segs.length - 1]));
  }
  // fix directory modes (umask-independent)
  const fixDirs = (dir) => { fs.chmodSync(dir, 0o755); for (const n of fs.readdirSync(dir)) { const p = path.join(dir, n); const st = fs.lstatSync(p); if (st.isDirectory()) fixDirs(p); } };
  fixDirs(dest);
  hashLines.sort();
  const lockEntry = entries.find((e) => e.rel === 'package-lock.json' && e.mode !== '120000');
  let lockfileSha256 = null;
  if (lockEntry) lockfileSha256 = sha(git(repo, ['cat-file', 'blob', lockEntry.oid]));
  return { treeSha256: sha(hashLines.join('')), lockfileSha256, fileCount: entries.length };
}

/** Create/verify every directory from root down. An existing non-directory or symlink is refused (host-side, before any container). */
function ensureRealDirs(root, segments, what) {
  let cur = root;
  for (const seg of segments) {
    cur = path.join(cur, seg);
    let st = null;
    try { st = fs.lstatSync(cur); } catch (e) { if (e.code !== 'ENOENT') throw e; }
    if (!st) { fs.mkdirSync(cur, { mode: 0o755 }); continue; }
    if (st.isSymbolicLink() || !st.isDirectory()) fail('path_violation', `${what} collides with a symlink or non-directory in the revision: ${path.relative(root, cur)}`);
  }
  return cur;
}

function overlayTests(workDir, cfg, inputs) {
  // testsRel '.' (revision root) is reachable only via an exact '.' selector (runner_config.testsRel / mutation --tests-rel).
  if (cfg.testsRel !== '.' && cfg.testsRel.split('/').some((s) => s === 'node_modules' || s.toLowerCase() === '.git')) fail('path_violation', `testsRel ${cfg.testsRel} uses a reserved path segment`);
  const base = cfg.testsRel === '.' ? workDir : ensureRealDirs(workDir, cfg.testsRel.split('/'), `testsRel ${cfg.testsRel}`);
  for (const f of inputs.files) {
    const segs = f.rel.split('/');
    // Defense in depth for a root-level overlay: no dot segments, VCS metadata or dependency directories.
    if (segs.some((s) => s === '.' || s === '..' || s.toLowerCase() === '.git' || s === 'node_modules')) fail('path_violation', `test file ${f.rel} uses a reserved path segment`);
    const parent = ensureRealDirs(base, segs.slice(0, -1), `test file ${f.rel}`);
    const abs = path.join(parent, segs[segs.length - 1]);
    try { fs.writeFileSync(abs, f.bytes, { flag: 'wx', mode: 0o644 }); } catch (e) { fail('path_violation', `test file ${f.rel} collides with the revision: ${e.code}`); }
    fs.chmodSync(abs, 0o644);
  }
  const fixDirs = (dir) => { fs.chmodSync(dir, 0o755); for (const n of fs.readdirSync(dir)) { const p = path.join(dir, n); if (fs.lstatSync(p).isDirectory()) fixDirs(p); } };
  fixDirs(base);
}

// --- dependency snapshot ---------------------------------------------------------------------

export function hashDependencies(depsDir, policy) {
  const lines = [];
  let count = 0;
  const walk = (abs, rel) => {
    for (const name of fs.readdirSync(abs)) {
      const p = path.join(abs, name); const r = `${rel}/${name}`;
      const st = fs.lstatSync(p);
      if (++count > policy.limits.maxDependencyFiles) fail('deps_invalid', 'dependency snapshot exceeds the file limit');
      if (st.isSymbolicLink()) lines.push(`l\0${r}\0${fs.readlinkSync(p)}\0`);
      else if (st.isDirectory()) { lines.push(`d\0${r}\0`); walk(p, r); }
      else if (st.isFile()) lines.push(`f\0${r}\0${sha256File(p)}\0`);
      else fail('deps_invalid', `special file in dependency snapshot: ${r}`);
    }
  };
  walk(path.join(depsDir, 'node_modules'), 'node_modules');
  const lockfileSha256 = sha256File(path.join(depsDir, 'package-lock.json'));
  lines.sort();
  return { depsSnapshotSha256: sha(`${lines.join('')}lock\0${lockfileSha256}\0`), lockfileSha256 };
}

// --- docker ----------------------------------------------------------------------------------

function dockerEnv() {
  const env = { PATH: process.env.PATH || '/usr/local/bin:/usr/bin:/bin', HOME: process.env.HOME || os.homedir() };
  for (const k of ['DOCKER_HOST', 'DOCKER_CONFIG', 'DOCKER_CONTEXT', 'DOCKER_CERT_PATH', 'DOCKER_TLS_VERIFY']) if (process.env[k]) env[k] = process.env[k];
  return env;
}
function docker(args, { timeout = 60000, input } = {}) {
  return spawnSync('docker', args, { env: dockerEnv(), encoding: 'utf8', timeout, maxBuffer: 64 * 1024 * 1024, input });
}
const activeContainers = new Set();
const cleanupPaths = new Set();
function forceRemove(name) {
  docker(['kill', name], { timeout: 20000 });
  docker(['rm', '-f', '-v', name], { timeout: 30000 });
  activeContainers.delete(name);
}

const SIDE_ROLES = { 'node-test.json': 'node_test_json', 'vitest.json': 'vitest_json', 'stdout.txt': 'stdout', 'stderr.txt': 'stderr', 'counterexample.txt': 'counterexample', 'mutation-report.json': 'stryker_report', 'mutation-budget.json': 'mutation_budget', 'domain-structure.json': 'domain_structure', 'domain-runtime.json': 'domain_runtime', 'domain-scene.json': 'domain_scene', 'domain-model.glb': 'domain_model', 'domain-beauty.png': 'domain_beauty' };

function sandboxProfile(policy, imageDigest, kind, mounts) {
  const l = policy.limits;
  return {
    id: policy.id, kind, imageDigest, network: 'none', readOnlyRootfs: true, capDrop: ['ALL'], noNewPrivileges: true,
    pidsLimit: l.pidsLimit, memoryBytes: l.memoryBytes, memorySwapBytes: l.memoryBytes, cpus: l.cpus, user: policy.user,
    ulimits: { fsize: l.fileSizeBytes, nofile: l.openFiles }, tmpMegabytes: l.tmpMegabytes,
    mounts: mounts.map((m) => ({ target: m.target, readonly: m.readonly })).sort((a, b) => a.target.localeCompare(b.target)),
    tmpfs: kind === 'mutate' ? ['/tmp', '/work'] : ['/tmp'],
  };
}

function createArgs({ policy, image, name, workdirTag, mounts, env, kind, argv }) {
  const l = policy.limits;
  const args = [
    'create', '--name', name, '--pull', 'never', '--label', 'atd.owner=eval-harness', '--label', `atd.workdir=${workdirTag}`,
    '--network', 'none', '--read-only', '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges',
    '--pids-limit', String(l.pidsLimit), '--memory', String(l.memoryBytes), '--memory-swap', String(l.memoryBytes), '--cpus', String(l.cpus),
    '--ulimit', `fsize=${l.fileSizeBytes}:${l.fileSizeBytes}`, '--ulimit', `nofile=${l.openFiles}:${l.openFiles}`,
    '--user', policy.user, '--workdir', '/work',
    '--log-driver', 'json-file', '--log-opt', `max-size=${l.logMaxSize || '1m'}`, '--log-opt', 'max-file=1',
    '--tmpfs', `/tmp:rw,nosuid,nodev,size=${l.tmpMegabytes}m,mode=1777`,
  ];
  if (kind === 'mutate') {
    const [uid, gid] = policy.user.split(':');
    args.push('--tmpfs', `/work:rw,nosuid,nodev,size=${l.mutationWorkMegabytes}m,uid=${uid},gid=${gid},mode=0755`);
  }
  for (const m of mounts) args.push('--mount', `type=bind,source=${mountSafe(m.source, 'mount source')},target=${m.target}${m.readonly ? ',readonly' : ''}`);
  for (const [k, v] of Object.entries(env)) args.push('-e', `${k}=${v}`);
  args.push('--entrypoint', 'node', image, ...argv);
  return args;
}

export function assertConfinement(inspect, { policy, mounts, env, kind }) {
  const hc = inspect.HostConfig || {};
  const problems = [];
  const eq = (cond, what) => { if (!cond) problems.push(what); };
  const l = policy.limits;
  eq(hc.NetworkMode === 'none', `NetworkMode=${hc.NetworkMode}`);
  eq(hc.ReadonlyRootfs === true, 'rootfs is not read-only');
  eq(Array.isArray(hc.CapDrop) && hc.CapDrop.map((c) => String(c).toUpperCase()).includes('ALL'), 'capabilities not dropped');
  eq(!hc.CapAdd || hc.CapAdd.length === 0, 'capabilities added');
  eq(hc.Privileged === false, 'privileged');
  eq(Array.isArray(hc.SecurityOpt) && hc.SecurityOpt.some((s) => String(s).startsWith('no-new-privileges')), 'no-new-privileges missing');
  eq(hc.PidsLimit === l.pidsLimit, `PidsLimit=${hc.PidsLimit}`);
  eq(hc.Memory === l.memoryBytes && hc.MemorySwap === l.memoryBytes, `Memory=${hc.Memory}/${hc.MemorySwap}`);
  eq(hc.NanoCpus === l.cpus * 1e9, `NanoCpus=${hc.NanoCpus}`);
  eq((inspect.Config || {}).User === policy.user, `User=${(inspect.Config || {}).User}`);
  eq(!hc.PidMode && !String(hc.IpcMode || '').startsWith('host') && !String(hc.IpcMode || '').startsWith('container:') && !hc.UsernsMode, 'host namespaces shared');
  eq(!hc.Devices || hc.Devices.length === 0, 'devices attached');
  eq(!hc.Binds || hc.Binds.length === 0, 'unexpected Binds');
  eq(!hc.VolumesFrom || hc.VolumesFrom.length === 0, 'VolumesFrom set');
  eq(!hc.Links || hc.Links.length === 0, 'Links set');
  const wantTmpfs = new Set(kind === 'mutate' ? ['/tmp', '/work'] : ['/tmp']);
  eq(JSON.stringify(Object.keys(hc.Tmpfs || {}).sort()) === JSON.stringify([...wantTmpfs].sort()), `tmpfs set ${JSON.stringify(Object.keys(hc.Tmpfs || {}))}`);
  const got = (inspect.Mounts || []).map((m) => ({ target: m.Destination, source: m.Source, rw: m.RW, type: m.Type })).sort((a, b) => a.target.localeCompare(b.target));
  const want = [...mounts].sort((a, b) => a.target.localeCompare(b.target));
  const realOrNull = (p) => { try { return fs.realpathSync(p); } catch { return null; } };
  eq(got.length === want.length && got.every((g, i) => g.type === 'bind' && g.target === want[i].target && g.rw === !want[i].readonly && realOrNull(g.source) !== null && realOrNull(g.source) === realOrNull(want[i].source)), `mounts differ: ${JSON.stringify(got)}`);
  const envKeys = ((inspect.Config || {}).Env || []).map((e) => e.split('=')[0]);
  const allowedKeys = new Set([...Object.keys(env), ...policy.env.imageDefaults]);
  eq(envKeys.every((k) => allowedKeys.has(k)), `unexpected environment: ${envKeys.filter((k) => !allowedKeys.has(k)).join(',')}`);
  if (problems.length) fail('sandbox_preflight', `effective confinement does not match the profile: ${problems.join('; ')}`);
}

function assertProbe(probe, policy, expectDeps) {
  const problems = [];
  const bad = (c, what) => { if (!c) problems.push(what); };
  const [uid, gid] = policy.user.split(':').map(Number);
  bad(probe.uid === uid && probe.gid === gid, `uid/gid=${probe.uid}/${probe.gid}`);
  bad(/^0+$/.test(probe.capEff || 'x') && /^0+$/.test(probe.capBnd || 'x'), `capabilities effective=${probe.capEff} bounding=${probe.capBnd}`);
  bad(probe.noNewPrivs === '1', 'NoNewPrivs != 1');
  bad(probe.rootfsWritable === false, 'rootfs writable');
  bad(probe.workWritable === false, '/work writable');
  bad(probe.atdWritable === false, '/atd writable');
  if (expectDeps) bad(probe.depsWritable === false, '/deps writable');
  bad(probe.tmpWritable === true && probe.outWritable === true, 'tmp/out not writable');
  bad(probe.tcp4 && probe.tcp4.connected === false && probe.tcp6 && probe.tcp6.connected === false, 'network egress possible');
  bad(probe.dns && probe.dns.resolved === false, 'DNS resolves');
  bad(Array.isArray(probe.hostSecrets) && probe.hostSecrets.length === 0, `host paths visible: ${(probe.hostSecrets || []).join(',')}`);
  const allowed = new Set([...Object.keys(policy.env.static), ...policy.env.seeded, ...policy.env.imageDefaults]);
  bad(probe.env.every((k) => allowed.has(k)), `unexpected environment variables: ${probe.env.filter((k) => !allowed.has(k)).join(',')}`);
  bad(typeof probe.nodeVersion === 'string' && probe.nodeVersion.startsWith(`v${policy.image.nodeMajor}.`), `node ${probe.nodeVersion}`);
  if (problems.length) fail('sandbox_preflight', `probe container violates the profile: ${problems.join('; ')}`);
}

function dockerReady(policy, image) {
  const v = docker(['version', '--format', '{{.Server.Version}}'], { timeout: 20000 });
  if (v.error || v.status !== 0) fail('sandbox_preflight', `Docker daemon is not reachable: ${(v.stderr || (v.error && v.error.message) || '').trim().slice(0, 200)}`);
  const i = docker(['image', 'inspect', image, '--format', '{{.Id}}|{{json .RepoDigests}}'], { timeout: 20000 });
  if (i.status !== 0) fail('sandbox_preflight', `pinned image ${image} is not present locally (pulls are disabled): ${(i.stderr || '').trim().slice(0, 200)}`);
  const [imageId, digests] = i.stdout.trim().split('|');
  const digest = image.slice(image.indexOf('@') + 1);
  let list = [];
  try { list = JSON.parse(digests) || []; } catch { /* handled below */ }
  if (!list.some((d) => d.endsWith(`@${digest}`))) fail('sandbox_preflight', `local image does not carry the pinned digest ${digest}`);
  return { dockerVersion: v.stdout.trim(), imageId, imageDigest: digest };
}

function stageContainerDir(tmp) {
  const dest = path.join(tmp, 'atd');
  fs.mkdirSync(dest, { recursive: true, mode: 0o755 });
  for (const name of fs.readdirSync(CONTAINER_DIR)) fs.copyFileSync(path.join(CONTAINER_DIR, name), path.join(dest, name));
  for (const name of fs.readdirSync(dest)) fs.chmodSync(path.join(dest, name), name === 'ps' ? 0o755 : 0o644);
  fs.chmodSync(dest, 0o755);
  return dest;
}

function containerEnv(policy, seed) {
  return { ...policy.env.static, ATD_SEED: String(seed), FC_SEED: String(seed) };
}

export async function preflight({ policyBundle, image, deps = null, quick = false, tmpRoot }) {
  const { policy } = policyBundle;
  const ready = dockerReady(policy, image);
  if (quick) return { ...ready, probed: false };
  const tmp = fs.mkdtempSync(path.join(tmpRoot, 'atd-probe-'));
  const name = `atd-probe-${randomUUID()}`;
  try {
    fs.chmodSync(tmp, 0o755);
    cleanupPaths.add(tmp);
    const atdDir = stageContainerDir(tmp);
    const workDir = path.join(tmp, 'work'); const outDir = path.join(tmp, 'out');
    fs.mkdirSync(workDir, { mode: 0o755 }); fs.mkdirSync(outDir); fs.chmodSync(outDir, 0o777);
    const mounts = [
      { source: workDir, target: '/work', readonly: true }, { source: atdDir, target: '/atd', readonly: true }, { source: outDir, target: '/out', readonly: false },
    ];
    if (deps) mounts.push({ source: path.join(deps, 'node_modules'), target: '/deps/node_modules', readonly: true }, { source: path.join(deps, 'package-lock.json'), target: '/deps/package-lock.json', readonly: true });
    const env = containerEnv(policy, 0);
    const created = docker(createArgs({ policy, image, name, workdirTag: 'probe', mounts, env, kind: 'test', argv: ['/atd/probe.mjs'] }));
    if (created.status !== 0) fail('sandbox_preflight', `cannot create probe container: ${(created.stderr || '').trim().slice(0, 300)}`);
    activeContainers.add(name);
    const insp = docker(['inspect', name]);
    if (insp.status !== 0) fail('sandbox_preflight', 'cannot inspect probe container');
    assertConfinement(JSON.parse(insp.stdout)[0], { policy, mounts, env, kind: 'test' });
    const started = docker(['start', '-a', name], { timeout: 60000 });
    if (started.status !== 0) fail('sandbox_preflight', `probe container failed: ${(started.stderr || '').trim().slice(0, 300)}`);
    let probe;
    try { probe = JSON.parse(started.stdout.trim().split('\n').pop()); } catch { fail('sandbox_preflight', 'probe produced no JSON'); }
    assertProbe(probe, policy, Boolean(deps));
    return { ...ready, probed: true, nodeVersion: probe.nodeVersion };
  } finally {
    forceRemove(name);
    fs.rmSync(tmp, { recursive: true, force: true });
  }
}

// --- one container execution -----------------------------------------------------------------

async function runContainer({ policy, image, name, workdirTag, mounts, env, kind, argv, timeoutMs }) {
  const args = createArgs({ policy, image, name, workdirTag, mounts, env, kind, argv });
  const created = docker(args);
  if (created.status !== 0) fail('sandbox_preflight', `cannot create container: ${(created.stderr || '').trim().slice(0, 300)}`);
  activeContainers.add(name);
  try {
    const pre = docker(['inspect', name]);
    if (pre.status !== 0) fail('sandbox_preflight', 'cannot inspect container before start');
    assertConfinement(JSON.parse(pre.stdout)[0], { policy, mounts, env, kind });
    const startedAt = new Date();
    let timedOut = false;
    const child = spawn('docker', ['start', '-a', name], { env: dockerEnv(), stdio: ['ignore', 'pipe', 'pipe'] });
    let diag = '';
    for (const s of [child.stdout, child.stderr]) s.on('data', (c) => { if (diag.length < 8192) diag += c.toString('utf8'); });
    const closed = new Promise((resolve) => { child.on('close', (code) => resolve(code)); child.on('error', () => resolve(-1)); });
    const timer = setTimeout(() => {
      timedOut = true;
      docker(['kill', name], { timeout: 20000 });
      setTimeout(() => { try { child.kill('SIGKILL'); } catch { /* exited */ } }, 10000).unref();
    }, timeoutMs);
    await closed;
    clearTimeout(timer);
    const endedAt = new Date();
    const post = docker(['inspect', name]);
    if (post.status !== 0) fail('infra', `container vanished: ${diag.slice(0, 200)}`);
    const state = JSON.parse(post.stdout)[0].State || {};
    if (!state.StartedAt || state.StartedAt.startsWith('0001-')) fail('infra', `container never started: ${diag.slice(0, 300)}`);
    return { exitCode: Number.isInteger(state.ExitCode) ? state.ExitCode : -1, timedOut, oomKilled: Boolean(state.OOMKilled), startedAt, endedAt, durationMs: endedAt - startedAt };
  } finally {
    forceRemove(name);
  }
}

// --- reporter interpretation -----------------------------------------------------------------

const ASSERTION_MESSAGE = /^(AssertionError\b|\w*Error \[ERR_ASSERTION\]|Error: Property failed after \d+ tests?)/;

function readReporter(file, max) {
  let st; try { st = fs.lstatSync(file); } catch { return { missing: true }; }
  if (!st.isFile()) return { invalid: 'reporter output is not a regular file' };
  if (st.size > max) return { invalid: 'reporter output exceeds the size bound' };
  try { return { json: JSON.parse(fs.readFileSync(file, 'utf8')) }; } catch { return { invalid: 'reporter output is not JSON' }; }
}

function interpretNode(report, expectedFile) {
  if (!report || report.schema !== 'atd.node-test-report/v1' || !Array.isArray(report.tests)) return { error: 'infra', detail: 'malformed node:test report' };
  const tests = report.tests.filter((t) => !t.isSuite);
  if (tests.some((t) => t.file !== expectedFile)) return { error: 'infra', detail: 'report references a file other than the requested test file' };
  if (tests.some((t) => t.failureKind === 'file')) return { error: 'compile', detail: 'test file could not be loaded' };
  const leaf = tests.filter((t) => t.failureKind !== 'subtests');
  const executed = leaf.filter((t) => t.status === 'pass' || t.status === 'fail');
  const failures = leaf.filter((t) => t.status === 'fail');
  return {
    executed: executed.length, passed: executed.length - failures.length, failed: failures.length, skipped: leaf.filter((t) => t.status === 'skip' || t.status === 'todo').length,
    assertionFailures: failures.filter((t) => t.failureKind === 'assertion' || t.failureKind === 'property').length,
    otherFailures: failures.filter((t) => t.failureKind !== 'assertion' && t.failureKind !== 'property').length,
    counterexample: failures.map((t) => t.message || '').find((m) => /Property failed after|Counterexample/.test(m)) || null,
  };
}

function interpretVitest(report, expectedFile) {
  if (!report || !Array.isArray(report.testResults)) return { error: 'infra', detail: 'malformed vitest report' };
  if (report.testResults.some((f) => f.name !== expectedFile)) return { error: 'infra', detail: 'report references a file other than the requested test file' };
  if (report.testResults.length === 0) return { error: 'no_tests_collected', detail: 'vitest collected no test file' };
  let executed = 0; let passed = 0; let failed = 0; let skipped = 0; let assertion = 0; let other = 0; let counterexample = null;
  for (const file of report.testResults) {
    const cases = Array.isArray(file.assertionResults) ? file.assertionResults : [];
    if (file.status === 'failed' && cases.length === 0) return { error: 'compile', detail: 'test file failed during collection' };
    // Suite-level faults (hook errors, unhandled errors recorded on the file) or a failed file with no failing case.
    if ((typeof file.message === 'string' && file.message.trim() !== '') || (file.status === 'failed' && cases.every((c) => c.status === 'passed'))) other += 1;
    for (const c of cases) {
      if (c.status === 'passed') { executed += 1; passed += 1; } else if (c.status === 'failed') {
        executed += 1; failed += 1;
        const first = String((c.failureMessages || [])[0] || '');
        if (ASSERTION_MESSAGE.test(first.trimStart())) assertion += 1; else other += 1;
        if (!counterexample && /Counterexample:/.test(first)) counterexample = first.slice(0, 4096);
      } else skipped += 1;
    }
  }
  return { executed, passed, failed, skipped, assertionFailures: assertion, otherFailures: other, counterexample };
}

export function deriveOutcome({ framework, run, reporterPath, expectedFile, policy }) {
  if (run.timedOut) return { outcome: 'error', errorClass: 'timeout', counts: null };
  if (run.oomKilled) return { outcome: 'error', errorClass: 'oom', counts: null };
  const rep = readReporter(reporterPath, policy.limits.maxReporterBytes);
  if (rep.missing) return { outcome: 'error', errorClass: 'infra', counts: null, detail: 'reporter output absent' };
  if (rep.invalid) return { outcome: 'error', errorClass: 'infra', counts: null, detail: rep.invalid };
  const r = framework === 'vitest' ? interpretVitest(rep.json, expectedFile) : interpretNode(rep.json, expectedFile);
  if (r.error) return { outcome: 'error', errorClass: r.error, counts: null, detail: r.detail };
  const counts = { executed: r.executed, passed: r.passed, failed: r.failed, skipped: r.skipped, assertionFailures: r.assertionFailures, otherFailures: r.otherFailures };
  const extra = r.counterexample ? { counterexample: r.counterexample } : {};
  if (r.executed === 0) return { outcome: 'error', errorClass: 'no_tests_collected', counts, ...extra };
  // Any collection/runtime/hook fault outranks assertion failures: a mixed run is never a finding.
  if (r.otherFailures > 0) return { outcome: 'error', errorClass: 'runtime_error', counts, ...extra };
  if (r.assertionFailures > 0) return run.exitCode !== 0 ? { outcome: 'fail', counts, ...extra } : { outcome: 'error', errorClass: 'infra', counts, detail: 'failures reported but exit code 0', ...extra };
  if (run.exitCode === 0) return { outcome: 'pass', counts };
  return { outcome: 'error', errorClass: 'infra', counts, detail: `exit code ${run.exitCode} without a reported failure` };
}

// --- sides -----------------------------------------------------------------------------------

function collectArtifacts(outDir, stageDir, side, policy, extraFiles = {}) {
  const artifacts = [];
  for (const [fname, role] of Object.entries(SIDE_ROLES)) {
    const src = path.join(outDir, fname);
    let st; try { st = fs.lstatSync(src); } catch { continue; }
    if (!st.isFile()) continue;
    const cap = role === 'stdout' || role === 'stderr' ? policy.limits.maxLogBytes + 128 : policy.limits.maxReporterBytes;
    if (st.size > cap) continue;
    const dest = `artifacts/${side}.${fname}`;
    fs.copyFileSync(src, path.join(stageDir, dest));
    artifacts.push({ role, path: dest, sha256: sha256File(path.join(stageDir, dest)) });
  }
  for (const [fname, content] of Object.entries(extraFiles)) {
    const dest = `artifacts/${side}.${fname}`;
    fs.writeFileSync(path.join(stageDir, dest), content);
    artifacts.push({ role: 'counterexample', path: dest, sha256: sha(content) });
  }
  return artifacts;
}

async function runSide({ side, cfg, inputs, policyBundle, image, imageInfo, nodeVersion, deps, tmp, stageDir, workdirTag, candidateId }) {
  const { policy, policySha256 } = policyBundle;
  const sideDir = path.join(tmp, side);
  const workDir = path.join(sideDir, 'work'); const outDir = path.join(sideDir, 'out');
  fs.mkdirSync(sideDir, { mode: 0o755 }); fs.mkdirSync(outDir); fs.chmodSync(outDir, 0o777);
  const commit = side === 'base' ? cfg.baseCommit : cfg.candidateCommit;
  const rev = await exportRevision(cfg.repository, commit, workDir, policy);
  if (!policy.frameworks[inputs.framework]) fail('config_invalid', 'unsupported framework');
  if (policy.frameworks[inputs.framework].requiresDependencies && !deps) fail('config_invalid', `${inputs.framework} requires runner_config.dependencies (a trusted dependency snapshot)`);
  overlayTests(workDir, cfg, inputs);
  if (deps) {
    try { fs.lstatSync(path.join(workDir, 'node_modules')); fail('export_invalid', 'revision tracks a node_modules path; dependencies must come from the snapshot'); } catch (e) { if (e instanceof AtdError) throw e; }
    fs.symlinkSync('/deps/node_modules', path.join(workDir, 'node_modules'));
  }
  const depsHash = deps ? hashDependencies(cfg.dependencies, policy) : { depsSnapshotSha256: null, lockfileSha256: null };
  const atdDir = stageContainerDir(sideDir);
  const mounts = [
    { source: workDir, target: '/work', readonly: true }, { source: atdDir, target: '/atd', readonly: true }, { source: outDir, target: '/out', readonly: false },
  ];
  if (deps) mounts.push({ source: path.join(cfg.dependencies, 'node_modules'), target: '/deps/node_modules', readonly: true }, { source: path.join(cfg.dependencies, 'package-lock.json'), target: '/deps/package-lock.json', readonly: true });
  const env = containerEnv(policy, cfg.seed);
  // Revision-relative placement ('.' = revision root); testFile is relative to the placement root, never /work/./x.
  const testRel = cfg.testsRel === '.' ? inputs.testFile : `${cfg.testsRel}/${inputs.testFile}`;
  const expectedFile = `/work/${testRel}`;
  const argv = ['/atd/exec.mjs', 'test', `--framework=${inputs.framework}`, `--test-path=${expectedFile}`, `--test-rel=${testRel}`, `--test-timeout-ms=${policy.frameworks.vitest.testTimeoutMs}`];
  const executionId = `exec_${randomUUID()}`;
  const run = await runContainer({ policy, image, name: `atd-${side}-${executionId.slice(5, 21)}`, workdirTag, mounts, env, kind: 'test', argv, timeoutMs: cfg.timeoutSeconds * 1000 });
  const reporterFile = inputs.framework === 'vitest' ? 'vitest.json' : 'node-test.json';
  const derived = deriveOutcome({ framework: inputs.framework, run, reporterPath: path.join(outDir, reporterFile), expectedFile, policy });
  const extra = derived.counterexample ? { 'counterexample.txt': Buffer.from(`${derived.counterexample}\n`) } : {};
  const artifacts = collectArtifacts(outDir, stageDir, side, policy, extra);
  const profile = sandboxProfile(policy, imageInfo.imageDigest, 'test', mounts);
  const record = {
    schema: 'atd.execution-record/v1', executionId, candidateId, side,
    revision: { commit, treeSha256: rev.treeSha256, lockfileSha256: rev.lockfileSha256 },
    testSha256: inputs.testSha256, testsTreeSha256: inputs.testsTreeSha256,
    depsSnapshotSha256: depsHash.depsSnapshotSha256, lockfileSha256: depsHash.lockfileSha256,
    image: { ref: image, digest: imageInfo.imageDigest, id: imageInfo.imageId }, nodeVersion,
    profile: { id: policy.id, policySha256 }, sandboxProfileSha256: sha(canonicalJson(profile)),
    argv: ['node', ...argv], env, seed: cfg.seed, framework: inputs.framework,
    startedAt: run.startedAt.toISOString(), endedAt: run.endedAt.toISOString(), durationMs: run.durationMs,
    exitCode: run.exitCode, timedOut: run.timedOut, outcome: derived.outcome,
    ...(derived.errorClass ? { errorClass: derived.errorClass } : {}),
    ...(derived.counts ? { counts: derived.counts } : {}),
    artifacts,
  };
  return record;
}

export function compareEnvironments(base, cand) {
  const mismatch = [];
  const same = (a, b) => JSON.stringify(canonicalizeSafe(a)) === JSON.stringify(canonicalizeSafe(b));
  const checks = {
    'image.digest': [base.image.digest, cand.image.digest], 'image.id': [base.image.id, cand.image.id], nodeVersion: [base.nodeVersion, cand.nodeVersion],
    depsSnapshotSha256: [base.depsSnapshotSha256, cand.depsSnapshotSha256], lockfileSha256: [base.lockfileSha256, cand.lockfileSha256],
    'revision.lockfileSha256': [base.revision.lockfileSha256, cand.revision.lockfileSha256], env: [base.env, cand.env], seed: [base.seed, cand.seed],
    argv: [base.argv, cand.argv], 'profile.policySha256': [base.profile.policySha256, cand.profile.policySha256], sandboxProfileSha256: [base.sandboxProfileSha256, cand.sandboxProfileSha256],
    testSha256: [base.testSha256, cand.testSha256], framework: [base.framework, cand.framework],
  };
  for (const [k, [a, b]] of Object.entries(checks)) if (!same(a, b)) mismatch.push(k);
  for (const r of [base, cand]) if (r.lockfileSha256 && r.revision.lockfileSha256 && r.lockfileSha256 !== r.revision.lockfileSha256) mismatch.push(`${r.side}.revisionLockfileDiffersFromSnapshot`);
  return mismatch;
}
function canonicalizeSafe(v) { try { return JSON.parse(canonicalJson(v ?? null)); } catch { return v; } }

export function matrixFor(base, cand) {
  if (base.outcome === 'error' || cand.outcome === 'error') return 'ERROR';
  return `${base.outcome === 'pass' ? 'PASS' : 'FAIL'}->${cand.outcome === 'pass' ? 'PASS' : 'FAIL'}`;
}

function scriptSha256() {
  const files = [RUNNER_SCRIPT, fileURLToPath(import.meta.url), path.join(HERE, 'attest.mjs'), ...fs.readdirSync(CONTAINER_DIR).sort().map((n) => path.join(CONTAINER_DIR, n))].filter((f) => fs.existsSync(f));
  const h = createHash('sha256');
  for (const f of files) h.update(`${path.basename(f)}\0${sha256File(f)}\0`);
  return h.digest('hex');
}

// --- main run --------------------------------------------------------------------------------

function tmpRootDir() {
  const root = fs.realpathSync(process.env.ATD_TMPDIR || os.tmpdir());
  return root;
}

export async function run({ workdir, transcript, rawConfig, env = process.env }) {
  const policyBundle = loadPolicy(env);
  const { policy, policySha256 } = policyBundle;
  const cfg = validateConfig(rawConfig, policyBundle, workdir);
  assertCommit(cfg.repository, cfg.baseCommit); assertCommit(cfg.repository, cfg.candidateCommit);
  const inputs = loadInputs(cfg, policy);
  const signer = resolveSigner({ stateDir: stateDirFrom(env), env, forbiddenRoots: [cfg.workdir, cfg.repository, CONTAINER_DIR, ...(cfg.dependencies ? [cfg.dependencies] : [])] });
  const tmpRoot = tmpRootDir();
  const pre = await preflight({ policyBundle, image: cfg.image, deps: cfg.dependencies, tmpRoot });
  const tmp = fs.mkdtempSync(path.join(tmpRoot, 'atd-run-'));
  fs.chmodSync(tmp, 0o755);
  const stageDir = path.join(cfg.workdir, `.atd-out.stage-${randomUUID().slice(0, 8)}`);
  cleanupPaths.add(tmp); cleanupPaths.add(stageDir);
  const workdirTag = sha(cfg.workdir).slice(0, 16);
  let published = false;
  try {
    fs.mkdirSync(path.join(stageDir, 'artifacts'), { recursive: true, mode: 0o755 });
    const common = { cfg, inputs, policyBundle, image: cfg.image, imageInfo: pre, nodeVersion: pre.nodeVersion, deps: cfg.dependencies, tmp, stageDir, workdirTag, candidateId: inputs.cand.id };
    const base = await runSide({ side: 'base', ...common });
    const candidate = await runSide({ side: 'candidate', ...common });
    const mismatch = compareEnvironments(base, candidate);
    if (cfg.dependencies) { // the snapshot must be unchanged across the whole run
      const after = hashDependencies(cfg.dependencies, policy);
      if (after.depsSnapshotSha256 !== candidate.depsSnapshotSha256) { mismatch.push('depsSnapshotModifiedDuringRun'); }
    }
    const differential = {
      schema: 'atd.differential/v1', candidateId: inputs.cand.id, base: base.executionId, candidate: candidate.executionId,
      matrix: matrixFor(base, candidate), environmentEqual: mismatch.length === 0, environmentMismatch: mismatch,
    };
    const write = (file, obj) => { const bytes = canonicalJson(obj); fs.writeFileSync(path.join(stageDir, file), bytes, { mode: 0o644 }); return sha(bytes); };
    const baseSha = write('base.json', base); const candSha = write('candidate.json', candidate); const diffSha = write('differential.json', differential);
    const artifactsList = [];
    for (const r of [base, candidate]) for (const a of r.artifacts) artifactsList.push({ path: a.path, sha256: a.sha256 });
    const attestation = {
      schema: 'atd.attestation/v1', kind: 'differential',
      runner: { id: 'atd-sandbox', scriptSha256: scriptSha256(), policySha256 },
      ehRunId: env.EVAL_RUN_ID || 'unknown', caseId: env.EVAL_CASE_ID || 'unknown', candidateId: inputs.cand.id,
      executions: [
        { executionId: base.executionId, side: 'base', recordFile: 'base.json', recordSha256: baseSha },
        { executionId: candidate.executionId, side: 'candidate', recordFile: 'candidate.json', recordSha256: candSha },
      ],
      differentialSha256: diffSha, candidateManifestSha256: inputs.candidateManifestSha256, specSha256: inputs.specSha256, testSha256: inputs.testSha256,
      artifacts: artifactsList, trust: signer.trust, signedAt: new Date().toISOString(),
    };
    const sealed = sealAttestation(stageDir, attestation, signer);
    const finalDir = path.join(cfg.workdir, 'atd-out');
    fs.rmSync(finalDir, { recursive: true, force: true });
    fs.renameSync(stageDir, finalDir);
    published = true;
    if (transcript) {
      const ts = () => new Date().toISOString();
      const lines = [
        { event: 'start', runner: 'atd-sandbox', candidateId: inputs.cand.id, ts: ts() },
        { event: 'step', type: 'differential', content: `matrix=${differential.matrix} base=${base.outcome} candidate=${candidate.outcome} environmentEqual=${differential.environmentEqual} trust=${signer.trust}`, ts: ts() },
        { event: 'result', matrix: differential.matrix, attestationSha256: sealed.attestationSha256, ts: ts() },
      ];
      fs.writeFileSync(transcript, `${lines.map((l) => JSON.stringify(l)).join('\n')}\n`);
    }
    return { differential, base, candidate, attestationSha256: sealed.attestationSha256 };
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
    if (!published) fs.rmSync(stageDir, { recursive: true, force: true });
  }
}

// --- mutation (Stryker inside the same confinement) --------------------------------------------

export async function mutation(opts, env = process.env) {
  const policyBundle = loadPolicy(env);
  const { policy, policySha256 } = policyBundle;
  if (!SHA1_RE.test(opts.commit || '')) fail('config_invalid', '--commit must be a full 40-hex SHA');
  for (const k of ['repository', 'dependencies', 'config', 'out']) if (!opts[k] || !path.isAbsolute(opts[k])) fail('config_invalid', `--${k} must be an absolute path`);
  const repository = realDir(opts.repository, 'repository');
  const dependencies = realDir(opts.dependencies, 'dependencies');
  assertCommit(repository, opts.commit);
  for (const [f, want] of [['node_modules', 'dir'], ['package-lock.json', 'file']]) {
    const st = fs.lstatSync(path.join(dependencies, f));
    if (st.isSymbolicLink() || (want === 'dir' ? !st.isDirectory() : !st.isFile())) fail('config_invalid', `dependency snapshot ${f} must be a plain ${want}`);
  }
  const timeoutSeconds = opts.timeout ? Number(opts.timeout) : policy.limits.maxMutationSeconds;
  if (!Number.isFinite(timeoutSeconds) || timeoutSeconds <= 0 || timeoutSeconds > policy.limits.maxMutationSeconds) fail('config_invalid', 'timeout out of bounds');
  let maxMutants = policy.limits.defaultMaxMutants;
  if (opts.maxMutants !== undefined && opts.maxMutants !== true) {
    if (!/^[0-9]+$/.test(String(opts.maxMutants))) fail('config_invalid', '--max-mutants must be a positive integer');
    maxMutants = Number(opts.maxMutants);
  } else if (opts.maxMutants === true) fail('config_invalid', '--max-mutants requires a value');
  if (!Number.isSafeInteger(maxMutants) || maxMutants < 1 || maxMutants > policy.limits.hardMaxMutants) fail('config_invalid', `--max-mutants must be in [1, ${policy.limits.hardMaxMutants}]`);
  const configBytes = readBounded(opts.config, policy.limits.maxCandidateBytes, 'stryker config');
  try { JSON.parse(configBytes.toString('utf8')); } catch { fail('config_invalid', 'stryker config is not JSON'); }
  const out = opts.out;
  const signer = resolveSigner({ stateDir: stateDirFrom(env), env, forbiddenRoots: [out, repository, dependencies, CONTAINER_DIR] });
  const tmpRoot = tmpRootDir();
  const pre = await preflight({ policyBundle, image: policy.image.ref, deps: dependencies, tmpRoot });
  const tmp = fs.mkdtempSync(path.join(tmpRoot, 'atd-mut-'));
  fs.chmodSync(tmp, 0o755);
  const stageDir = `${out}.stage-${randomUUID().slice(0, 8)}`;
  cleanupPaths.add(tmp); cleanupPaths.add(stageDir);
  let published = false;
  try {
    fs.mkdirSync(path.join(stageDir, 'artifacts'), { recursive: true, mode: 0o755 });
    const srcDir = path.join(tmp, 'src'); const outDir = path.join(tmp, 'out'); fs.mkdirSync(outDir); fs.chmodSync(outDir, 0o777);
    const rev = await exportRevision(repository, opts.commit, srcDir, policy);
    let testsTreeSha256 = sha('');
    if (opts.testsDir) {
      const testsDir = realDir(opts.testsDir, 'tests dir');
      const files = [];
      const walk = (abs, rel) => { for (const n of fs.readdirSync(abs).sort()) { const p = path.join(abs, n); const r = rel ? `${rel}/${n}` : n; const st = fs.lstatSync(p); if (st.isSymbolicLink() || (!st.isFile() && !st.isDirectory())) fail('path_violation', `unsafe entry in tests dir: ${r}`); if (st.isDirectory()) walk(p, r); else { if (!REL_PATH_RE.test(r)) fail('path_violation', `unsafe test path ${r}`); files.push({ rel: r, bytes: fs.readFileSync(p) }); } } };
      walk(testsDir, '');
      // '.' is an explicit, exact selector meaning the revision root; every other value must be a safe relative directory.
      const rel = opts.testsRel === '.' ? '.' : safeRel(opts.testsRel || 'tests', '--tests-rel');
      overlayTests(srcDir, { testsRel: rel }, { files });
      testsTreeSha256 = sha(files.map((f) => `${f.rel}\0${sha(f.bytes)}\0`).join(''));
    }
    const depsHash = hashDependencies(dependencies, policy);
    const atdDir = stageContainerDir(tmp);
    fs.writeFileSync(path.join(atdDir, 'stryker.conf.json'), configBytes, { mode: 0o644 });
    const mounts = [
      { source: srcDir, target: '/src', readonly: true }, { source: atdDir, target: '/atd', readonly: true }, { source: outDir, target: '/out', readonly: false },
      { source: path.join(dependencies, 'node_modules'), target: '/deps/node_modules', readonly: true }, { source: path.join(dependencies, 'package-lock.json'), target: '/deps/package-lock.json', readonly: true },
    ];
    const env2 = { ...containerEnv(policy, opts.seed ? Number(opts.seed) : 1), ATD_MAX_MUTANTS: String(maxMutants) };
    const executionId = `exec_${randomUUID()}`;
    const argv = ['/atd/exec.mjs', 'mutate', `--max-mutants=${maxMutants}`];
    const run = await runContainer({ policy, image: policy.image.ref, name: `atd-mut-${executionId.slice(5, 21)}`, workdirTag: sha(out).slice(0, 16), mounts, env: env2, kind: 'mutate', argv, timeoutMs: timeoutSeconds * 1000 });
    const artifacts = collectArtifacts(outDir, stageDir, 'mutant', policy);
    const report = artifacts.find((a) => a.role === 'stryker_report');
    let parsed = false;
    if (report) { try { JSON.parse(fs.readFileSync(path.join(stageDir, report.path), 'utf8')); parsed = true; } catch { parsed = false; } }
    const budgetArt = artifacts.find((a) => a.role === 'mutation_budget');
    let budget = null;
    if (budgetArt) { try { budget = JSON.parse(fs.readFileSync(path.join(stageDir, budgetArt.path), 'utf8')); } catch { budget = null; } }
    const budgetOk = Boolean(budget) && budget.schema === 'atd.mutation-budget/v1' && budget.maxMutants === maxMutants && Number.isSafeInteger(budget.planned) && typeof budget.allowed === 'boolean';
    let reportedMutants = null;
    if (parsed) { try { const rep = JSON.parse(fs.readFileSync(path.join(stageDir, report.path), 'utf8')); reportedMutants = Object.values(rep.files || {}).reduce((n, f) => n + (f && Array.isArray(f.mutants) ? f.mutants.length : 0), 0); } catch { reportedMutants = null; } }
    let outcome;
    if (run.timedOut) outcome = { outcome: 'error', errorClass: 'timeout' };
    else if (run.oomKilled) outcome = { outcome: 'error', errorClass: 'oom' };
    else if (run.exitCode === 86 && budgetOk && budget.allowed === false && budget.planned > maxMutants) outcome = { outcome: 'error', errorClass: 'budget_exceeded' };
    else if (run.exitCode === 0 && parsed && budgetOk && budget.allowed === true && budget.planned <= maxMutants && reportedMutants !== null && reportedMutants <= maxMutants) outcome = { outcome: 'pass' };
    else if (parsed && reportedMutants !== null && reportedMutants > maxMutants) outcome = { outcome: 'error', errorClass: 'budget_exceeded' }; // guard bypassed: never a success
    else if (run.exitCode === 0 && parsed && !budgetOk) outcome = { outcome: 'error', errorClass: 'infra' }; // budget reporter did not run
    else outcome = { outcome: 'error', errorClass: parsed ? 'infra' : 'no_tests_collected' };
    const candidateId = opts.candidateId && CASE_ID_RE.test(opts.candidateId) ? opts.candidateId : 'mutation';
    const record = {
      schema: 'atd.execution-record/v1', executionId, candidateId, side: 'mutant',
      revision: { commit: opts.commit, treeSha256: rev.treeSha256, lockfileSha256: rev.lockfileSha256 },
      testSha256: testsTreeSha256, testsTreeSha256, depsSnapshotSha256: depsHash.depsSnapshotSha256, lockfileSha256: depsHash.lockfileSha256,
      image: { ref: policy.image.ref, digest: pre.imageDigest, id: pre.imageId }, nodeVersion: pre.nodeVersion,
      profile: { id: policy.id, policySha256 }, sandboxProfileSha256: sha(canonicalJson(sandboxProfile(policy, pre.imageDigest, 'mutate', mounts))),
      argv: ['node', ...argv], env: env2, seed: opts.seed ? Number(opts.seed) : 1, framework: 'stryker',
      mutationBudget: { maxMutants, planned: budgetOk ? budget.planned : null, allowed: budgetOk ? budget.allowed : null, reportedMutants },
      startedAt: run.startedAt.toISOString(), endedAt: run.endedAt.toISOString(), durationMs: run.durationMs, exitCode: run.exitCode, timedOut: run.timedOut,
      ...outcome, artifacts,
    };
    const bytes = canonicalJson(record);
    fs.writeFileSync(path.join(stageDir, 'mutant.json'), bytes);
    const attestation = {
      schema: 'atd.attestation/v1', kind: 'mutation', runner: { id: 'atd-sandbox', scriptSha256: scriptSha256(), policySha256 },
      ehRunId: env.EVAL_RUN_ID || 'unknown', caseId: env.EVAL_CASE_ID || 'unknown', candidateId,
      executions: [{ executionId, side: 'mutant', recordFile: 'mutant.json', recordSha256: sha(bytes) }],
      candidateManifestSha256: sha(configBytes), specSha256: null, testSha256: testsTreeSha256,
      artifacts: artifacts.map((a) => ({ path: a.path, sha256: a.sha256 })), trust: signer.trust, signedAt: new Date().toISOString(),
    };
    sealAttestation(stageDir, attestation, signer);
    fs.rmSync(out, { recursive: true, force: true });
    fs.renameSync(stageDir, out);
    published = true;
    return record;
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
    if (!published) fs.rmSync(stageDir, { recursive: true, force: true });
  }
}

export function fingerprint(rawConfig, env = process.env) {
  const { policySha256, policy } = loadPolicy(env);
  return sha([scriptSha256(), policySha256, policy.image.digest, canonicalJson(rawConfig ?? {})].join('\0'));
}

export function teardown(workdir) {
  const real = (() => { try { return fs.realpathSync(workdir); } catch { return workdir; } })();
  const tag = sha(real).slice(0, 16);
  const ls = docker(['ps', '-aq', '--filter', 'label=atd.owner=eval-harness', '--filter', `label=atd.workdir=${tag}`], { timeout: 20000 });
  if (ls.status !== 0) return 0;
  let n = 0;
  for (const id of ls.stdout.split('\n').map((s) => s.trim()).filter(Boolean)) { docker(['rm', '-f', '-v', id], { timeout: 30000 }); n += 1; }
  return n;
}

// --- CLI -------------------------------------------------------------------------------------

function parseArgs(argv) {
  const out = {};
  for (const a of argv) { if (!a.startsWith('--')) continue; const i = a.indexOf('='); if (i < 0) out[a.slice(2)] = true; else out[a.slice(2, i)] = a.slice(i + 1); }
  return out;
}
async function readStdin() { const chunks = []; for await (const c of process.stdin) chunks.push(c); return Buffer.concat(chunks).toString('utf8'); }

function installSignalCleanup() {
  const cleanup = (code) => () => {
    for (const name of [...activeContainers]) forceRemove(name);
    for (const p of [...cleanupPaths]) { try { fs.rmSync(p, { recursive: true, force: true }); } catch { /* best effort */ } }
    process.exit(code);
  };
  process.on('SIGTERM', cleanup(143)); process.on('SIGINT', cleanup(130)); process.on('SIGHUP', cleanup(129));
}

async function cli(argv) {
  const [cmd, ...rest] = argv;
  const args = parseArgs(rest);
  installSignalCleanup();
  try {
    if (cmd === 'run') {
      if (!args.workdir) fail('config_invalid', '--workdir is required');
      let raw;
      try { raw = JSON.parse(await readStdin()); } catch { fail('config_invalid', 'runner_config JSON on stdin is not valid'); }
      const res = await run({ workdir: path.resolve(args.workdir), transcript: args.transcript ? path.resolve(args.transcript) : null, rawConfig: raw });
      process.stderr.write(`[atd-sandbox] matrix=${res.differential.matrix} environmentEqual=${res.differential.environmentEqual} base=${res.base.executionId} candidate=${res.candidate.executionId}\n`);
      return 0;
    }
    if (cmd === 'preflight') {
      const policyBundle = loadPolicy();
      let deps = null;
      if (args.dependencies) deps = realDir(args.dependencies, 'dependencies');
      if (args.image && !policyBundle.policy.allowedImages.includes(args.image)) fail('config_invalid', 'image is not allowed by policy');
      const res = await preflight({ policyBundle, image: args.image || policyBundle.policy.image.ref, deps, quick: Boolean(args.quick), tmpRoot: tmpRootDir() });
      process.stdout.write(`${JSON.stringify(res)}\n`);
      return 0;
    }
    if (cmd === 'fingerprint') {
      let raw = {}; const text = await readStdin();
      if (text.trim()) { try { raw = JSON.parse(text); } catch { raw = {}; } }
      process.stdout.write(`${fingerprint(raw)}\n`);
      return 0;
    }
    if (cmd === 'teardown') { process.stdout.write(`${teardown(args.workdir || '')}\n`); return 0; }
    if (cmd === 'mutation') {
      const rec = await mutation({ repository: args.repository, commit: args.commit, dependencies: args.dependencies, config: args.config, out: args.out, testsDir: args['tests-dir'], testsRel: args['tests-rel'], timeout: args.timeout, seed: args.seed, candidateId: args['candidate-id'], maxMutants: args['max-mutants'] });
      process.stdout.write(`${JSON.stringify({ executionId: rec.executionId, outcome: rec.outcome, errorClass: rec.errorClass ?? null, out: args.out })}\n`);
      return rec.outcome === 'pass' ? 0 : 1;
    }
    process.stderr.write('usage: sandbox.mjs run|preflight|fingerprint|teardown|mutation ...\n');
    return 2;
  } catch (error) {
    process.stderr.write(`[atd-sandbox] ${error instanceof AtdError ? `${error.code}: ` : ''}${error.message}\n`);
    return EXIT_INFRA;
  } finally {
    for (const name of [...activeContainers]) forceRemove(name);
  }
}

const isMain = (() => { try { return Boolean(process.argv[1]) && fs.realpathSync(process.argv[1]) === fs.realpathSync(fileURLToPath(import.meta.url)); } catch { return false; } })();
if (isMain) process.exitCode = await cli(process.argv.slice(2));
