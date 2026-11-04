// Private helpers shared by risk.mjs, candidates.mjs and mutation.mjs.
// Dependency-free Node ESM (Node >= 18). Never executes untrusted code: git is run with
// execFileSync (no shell) and a scrubbed environment; no file content is ever evaluated.
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export class DiscoveryError extends Error {
  constructor(code, message) {
    super(message);
    this.name = 'DiscoveryError';
    this.code = code;
  }
}

export const sha256 = (data) => createHash('sha256').update(data).digest('hex');

const SHA1_RE = /^[0-9a-f]{40}$/;
const SHA256_RE = /^[0-9a-f]{64}$/;
export const isSha1 = (v) => typeof v === 'string' && SHA1_RE.test(v);
export const isSha256 = (v) => typeof v === 'string' && SHA256_RE.test(v);

// ---------------------------------------------------------------------------
// Canonical JSON: keys sorted, UTF-8, no NaN/Infinity, no undefined members.
// ---------------------------------------------------------------------------
export function canonicalize(value) {
  if (value === null) return null;
  if (Array.isArray(value)) return value.map((v) => canonicalize(v === undefined ? null : v));
  switch (typeof value) {
    case 'string':
    case 'boolean':
      return value;
    case 'number':
      if (!Number.isFinite(value)) throw new DiscoveryError('invalid_number', 'non-finite number in canonical JSON');
      return value;
    case 'object': {
      const out = {};
      for (const key of Object.keys(value).sort()) {
        if (value[key] === undefined) continue;
        out[key] = canonicalize(value[key]);
      }
      return out;
    }
    default:
      throw new DiscoveryError('invalid_value', `unsupported value type in canonical JSON: ${typeof value}`);
  }
}
export const canonicalJson = (value) => JSON.stringify(canonicalize(value));
export const canonicalSha256 = (value) => sha256(canonicalJson(value));

// ---------------------------------------------------------------------------
// Safe relative paths (repository / tests-dir relative). Pure string validation.
// ---------------------------------------------------------------------------
const SAFE_SEGMENT_RE = /^[A-Za-z0-9_@+][A-Za-z0-9._@+-]*$/;
export function checkSafeRelativePath(p, { maxLength = 240 } = {}) {
  if (typeof p !== 'string' || p.length === 0) return 'path must be a non-empty string';
  if (p.length > maxLength) return `path longer than ${maxLength} characters`;
  if (p.includes('\0')) return 'path contains NUL';
  if (p.includes('\\')) return 'path contains a backslash';
  if (p.startsWith('/')) return 'path is absolute';
  if (/^[A-Za-z]:/.test(p)) return 'path has a drive prefix';
  const segments = p.split('/');
  for (const seg of segments) {
    if (seg === '' || seg === '.' || seg === '..') return 'path has an empty, "." or ".." segment';
    if (!SAFE_SEGMENT_RE.test(seg)) return `path segment ${JSON.stringify(seg)} has unsupported characters`;
  }
  return null;
}
export const isSafeRelativePath = (p, opts) => checkSafeRelativePath(p, opts) === null;

// ---------------------------------------------------------------------------
// git (read-only plumbing, no shell, no repository-controlled commands)
// ---------------------------------------------------------------------------
const GIT_BASE_ARGS = [
  '-c', 'core.quotepath=off',
  '-c', 'core.fsmonitor=false',
  '-c', 'core.hooksPath=/dev/null',
  '-c', 'diff.external=',
  '-c', 'diff.algorithm=myers',
  '-c', 'diff.renames=false',
];

function gitEnv() {
  return {
    PATH: process.env.PATH || '/usr/bin:/bin',
    HOME: '/nonexistent',
    LC_ALL: 'C',
    GIT_CONFIG_NOSYSTEM: '1',
    GIT_CONFIG_GLOBAL: '/dev/null',
    GIT_TERMINAL_PROMPT: '0',
    GIT_OPTIONAL_LOCKS: '0',
  };
}

export function git(repository, args, { maxBuffer = 256 * 1024 * 1024, allowFail = false } = {}) {
  if (typeof repository !== 'string' || repository === '' || repository.includes('\0')) {
    throw new DiscoveryError('invalid_repository', 'repository must be a non-empty path');
  }
  try {
    return execFileSync('git', ['-C', repository, ...GIT_BASE_ARGS, ...args], {
      env: gitEnv(),
      maxBuffer,
      stdio: ['ignore', 'pipe', 'pipe'],
    });
  } catch (err) {
    if (allowFail) return null;
    const stderr = err && err.stderr ? String(err.stderr).trim().split('\n').slice(-2).join(' ') : '';
    throw new DiscoveryError('git_failed', `git ${args[0]} failed${stderr ? `: ${stderr}` : ''}`);
  }
}

export function resolveCommit(repository, rev, label = 'revision') {
  if (typeof rev !== 'string' || rev === '' || rev.startsWith('-') || rev.includes('\0') || /\s/.test(rev)) {
    throw new DiscoveryError('invalid_revision', `${label} must be a commit-ish without whitespace or leading '-'`);
  }
  const out = git(repository, ['rev-parse', '--verify', '--end-of-options', `${rev}^{commit}`]).toString('utf8').trim();
  if (!isSha1(out)) throw new DiscoveryError('invalid_revision', `${label} did not resolve to a 40-hex commit`);
  return out;
}

export function readBlob(repository, commit, file) {
  if (typeof file !== 'string' || file === '' || file.includes('\0') || file.startsWith('/') || file.split('/').some((seg) => seg === '' || seg === '..' || seg === '.')) {
    throw new DiscoveryError('invalid_path', `unsafe repository path ${JSON.stringify(file)}`);
  }
  return git(repository, ['cat-file', 'blob', `${commit}:${file}`], { allowFail: true }); // Buffer | null (absent)
}

export const SOURCE_EXTENSIONS = new Set(['.js', '.mjs', '.cjs', '.jsx', '.ts', '.mts', '.cts', '.tsx']);
export function sourceExtension(file) {
  const m = /\.[A-Za-z]+$/.exec(file);
  return m && SOURCE_EXTENSIONS.has(m[0]) ? m[0] : null;
}
const TEST_NAME_RE = /\.(?:test|spec)\.[cm]?[jt]sx?$/;
const TEST_DIR_SEGMENTS = new Set(['__tests__', '__mocks__', 'test', 'tests', 'e2e', '__snapshots__', 'fixtures', '__fixtures__']);
export function isTestPath(file) {
  if (TEST_NAME_RE.test(file)) return true;
  return file.split('/').slice(0, -1).some((seg) => TEST_DIR_SEGMENTS.has(seg));
}

// ---------------------------------------------------------------------------
// Spec loading: null | file-path string | Buffer | Uint8Array | {path} | {text}
// ---------------------------------------------------------------------------
export const MAX_SPEC_BYTES = 1024 * 1024;
export function loadSpec(spec) {
  if (spec === null || spec === undefined) return null;
  let bytes;
  if (typeof spec === 'string' || (spec && typeof spec === 'object' && typeof spec.path === 'string')) {
    const p = typeof spec === 'string' ? spec : spec.path;
    let st;
    try {
      st = fs.statSync(p);
    } catch {
      throw new DiscoveryError('spec_unreadable', `spec file not readable: ${p}`);
    }
    if (!st.isFile()) throw new DiscoveryError('spec_invalid', `spec is not a regular file: ${p}`);
    if (st.size > MAX_SPEC_BYTES) throw new DiscoveryError('spec_too_large', `spec exceeds ${MAX_SPEC_BYTES} bytes`);
    bytes = fs.readFileSync(p);
  } else if (Buffer.isBuffer(spec) || spec instanceof Uint8Array) {
    bytes = Buffer.from(spec);
  } else if (spec && typeof spec === 'object' && typeof spec.text === 'string') {
    bytes = Buffer.from(spec.text, 'utf8');
  } else {
    throw new DiscoveryError('spec_invalid', 'spec must be null, a path string, Buffer, {path} or {text}');
  }
  if (bytes.length > MAX_SPEC_BYTES) throw new DiscoveryError('spec_too_large', `spec exceeds ${MAX_SPEC_BYTES} bytes`);
  let text;
  try {
    text = new TextDecoder('utf-8', { fatal: true }).decode(bytes);
  } catch {
    throw new DiscoveryError('spec_invalid', 'spec is not valid UTF-8');
  }
  return { bytes, text, sha256: sha256(bytes) };
}

// ---------------------------------------------------------------------------
// Minimal JSON-schema validator (the subset used by scripts/eval/discovery/schemas).
// ---------------------------------------------------------------------------
const SCHEMA_DIR = path.join(path.dirname(fileURLToPath(import.meta.url)), 'schemas');
const schemaCache = new Map();
export function loadSchema(name) {
  if (!/^atd\.[a-z-]+\.v\d+\.json$/.test(name)) throw new DiscoveryError('invalid_schema', `bad schema name ${name}`);
  if (!schemaCache.has(name)) schemaCache.set(name, JSON.parse(fs.readFileSync(path.join(SCHEMA_DIR, name), 'utf8')));
  return schemaCache.get(name);
}

function typeOf(v) {
  if (v === null) return 'null';
  if (Array.isArray(v)) return 'array';
  if (typeof v === 'number') return Number.isInteger(v) ? 'integer' : 'number';
  return typeof v;
}
const typeMatches = (want, v) => {
  const t = typeOf(v);
  return want === t || (want === 'number' && t === 'integer');
};

export function validateSchema(schema, value, root = schema, at = '$') {
  const errors = [];
  const walk = (s, v, p) => {
    if (s.$ref) {
      const ref = s.$ref;
      if (!ref.startsWith('#/')) throw new DiscoveryError('invalid_schema', `unsupported $ref ${ref}`);
      let target = root;
      for (const part of ref.slice(2).split('/')) target = target && target[part];
      if (!target) throw new DiscoveryError('invalid_schema', `unresolved $ref ${ref}`);
      return walk(target, v, p);
    }
    if (s.const !== undefined && canonicalJson(s.const) !== canonicalJson(v)) errors.push({ path: p, message: `must equal ${JSON.stringify(s.const)}` });
    if (s.enum && !s.enum.some((e) => canonicalJson(e) === canonicalJson(v))) errors.push({ path: p, message: `must be one of ${JSON.stringify(s.enum)}` });
    if (s.type) {
      const wants = Array.isArray(s.type) ? s.type : [s.type];
      if (!wants.some((w) => typeMatches(w, v))) {
        errors.push({ path: p, message: `must be of type ${wants.join('|')}` });
        return;
      }
    }
    if (s.oneOf) {
      const matches = s.oneOf.filter((sub) => validateSchema(sub, v, root, p).length === 0).length;
      if (matches !== 1) errors.push({ path: p, message: 'must match exactly one alternative' });
    }
    if (typeof v === 'string') {
      if (s.minLength !== undefined && v.length < s.minLength) errors.push({ path: p, message: `shorter than ${s.minLength}` });
      if (s.maxLength !== undefined && v.length > s.maxLength) errors.push({ path: p, message: `longer than ${s.maxLength}` });
      if (s.pattern && !new RegExp(s.pattern).test(v)) errors.push({ path: p, message: `must match ${s.pattern}` });
    }
    if (typeof v === 'number') {
      if (s.minimum !== undefined && v < s.minimum) errors.push({ path: p, message: `below minimum ${s.minimum}` });
      if (s.maximum !== undefined && v > s.maximum) errors.push({ path: p, message: `above maximum ${s.maximum}` });
    }
    if (Array.isArray(v)) {
      if (s.minItems !== undefined && v.length < s.minItems) errors.push({ path: p, message: `fewer than ${s.minItems} items` });
      if (s.maxItems !== undefined && v.length > s.maxItems) errors.push({ path: p, message: `more than ${s.maxItems} items` });
      if (s.items) v.forEach((item, i) => walk(s.items, item, `${p}[${i}]`));
    }
    if (v && typeof v === 'object' && !Array.isArray(v)) {
      for (const req of s.required || []) if (!Object.prototype.hasOwnProperty.call(v, req)) errors.push({ path: p, message: `missing required property ${req}` });
      const props = s.properties || {};
      for (const [k, sub] of Object.entries(props)) if (Object.prototype.hasOwnProperty.call(v, k)) walk(sub, v[k], `${p}.${k}`);
      if (s.additionalProperties !== undefined && s.additionalProperties !== true) {
        for (const k of Object.keys(v)) {
          if (Object.prototype.hasOwnProperty.call(props, k)) continue;
          if (s.additionalProperties === false) errors.push({ path: `${p}.${k}`, message: 'unknown property' });
          else walk(s.additionalProperties, v[k], `${p}.${k}`);
        }
      }
    }
  };
  walk(schema, value, at);
  return errors;
}

// ---------------------------------------------------------------------------
// CLI helpers
// ---------------------------------------------------------------------------
export function parseFlags(argv, { boolean = [] } = {}) {
  const flags = {};
  const positional = [];
  for (const arg of argv) {
    if (arg === '--help' || arg === '-h') {
      flags.help = true;
    } else if (arg.startsWith('--')) {
      const eq = arg.indexOf('=');
      const key = eq === -1 ? arg.slice(2) : arg.slice(2, eq);
      if (!/^[a-z][a-z0-9-]*$/.test(key)) throw new DiscoveryError('usage', `unknown flag ${arg}`);
      if (eq === -1) {
        if (!boolean.includes(key)) throw new DiscoveryError('usage', `flag --${key} requires a value (--${key}=VALUE)`);
        flags[key] = true;
      } else {
        flags[key] = arg.slice(eq + 1);
      }
    } else {
      positional.push(arg);
    }
  }
  return { flags, positional };
}

export function requireFlags(flags, names) {
  for (const n of names) if (typeof flags[n] !== 'string' || flags[n] === '') throw new DiscoveryError('usage', `missing required --${n}=VALUE`);
}

export function writeJsonFile(file, value) {
  const dest = path.resolve(file);
  let st = null;
  try { st = fs.lstatSync(dest); } catch { /* new file */ }
  if (st && st.isSymbolicLink()) throw new DiscoveryError('unsafe_output', `refusing to write through symlink ${dest}`);
  fs.mkdirSync(path.dirname(dest), { recursive: true });
  const tmp = `${dest}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, `${canonicalJson(value)}\n`, { flag: 'wx', mode: 0o644 });
  fs.renameSync(tmp, dest);
}

export function readJsonFile(file, { maxBytes = 16 * 1024 * 1024 } = {}) {
  let st;
  try { st = fs.statSync(file); } catch { throw new DiscoveryError('unreadable', `cannot read ${file}`); }
  if (!st.isFile()) throw new DiscoveryError('unreadable', `${file} is not a regular file`);
  if (st.size > maxBytes) throw new DiscoveryError('too_large', `${file} exceeds ${maxBytes} bytes`);
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8'));
  } catch {
    throw new DiscoveryError('invalid_json', `${file} is not valid JSON`);
  }
}

/** True when the module is the process entry point (symlink-safe). */
export function isMain(metaUrl) {
  try {
    return !!process.argv[1] && fs.realpathSync(process.argv[1]) === fs.realpathSync(fileURLToPath(metaUrl));
  } catch {
    return false;
  }
}

export async function runCli(main) {
  try {
    const code = await main(process.argv.slice(2));
    process.exitCode = code || 0;
  } catch (err) {
    if (err instanceof DiscoveryError) {
      process.stderr.write(`error [${err.code}]: ${err.message}\n`);
      process.exitCode = err.code === 'usage' ? 2 : 1;
    } else {
      process.stderr.write(`internal error: ${err && err.stack ? err.stack : err}\n`);
      process.exitCode = 1;
    }
  }
}
