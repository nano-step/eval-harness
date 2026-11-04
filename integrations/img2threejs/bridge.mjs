#!/usr/bin/env node
// Convert authenticated sandbox evidence into independent metric_score inputs.
import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { inflateSync } from 'node:zlib';
import { fileURLToPath } from 'node:url';
import { verifyOutDir, canonicalJson } from '../../scripts/eval/discovery/attest.mjs';

const [evidenceDir, metricsDir, productRoot, approvalFile] = process.argv.slice(2);
if (!evidenceDir || !metricsDir || !productRoot || ![evidenceDir, metricsDir, productRoot].every(path.isAbsolute) || (approvalFile && !path.isAbsolute(approvalFile))) throw new Error('usage: node bridge.mjs ABS_ATD_OUT ABS_EMPTY_METRICS ABS_PRODUCT_ROOT [ABS_APPROVAL_JSON]');
const verified = verifyOutDir(evidenceDir);
if (verified.status !== 'valid') throw new Error(`attestation ${verified.status}: ${verified.reason}`);
if (fs.readdirSync(metricsDir).length) throw new Error('metrics directory must be empty');
const evidenceRoot = fs.realpathSync(evidenceDir), metricRoot = fs.realpathSync(metricsDir);
const contained = (p, root) => p === root || p.startsWith(root + path.sep);
if (contained(metricRoot, evidenceRoot) || contained(evidenceRoot, metricRoot)) throw new Error('metrics and evidence directories must be separate');
const record = JSON.parse(fs.readFileSync(path.join(evidenceRoot, 'candidate.json'), 'utf8'));
const artifact = (role) => {
  const list = record.artifacts.filter((a) => a.role === role);
  if (list.length !== 1) return null;
  return path.join(evidenceRoot, list[0].path);
};
const helperDir = path.dirname(fileURLToPath(import.meta.url));
const helperNames = ['browser.mjs', 'domain-config.json', 'domain.test.mjs', 'structure.mjs'];
const digestBytes = (data) => createHash('sha256').update(data).digest('hex');
const trustedTree = digestBytes(helperNames.map((name) => `${name}\0${digestBytes(fs.readFileSync(path.join(helperDir, name)))}\0`).join(''));
if (record.testSha256 !== digestBytes(fs.readFileSync(path.join(helperDir, 'domain.test.mjs'))) || record.testsTreeSha256 !== trustedTree) throw new Error('signed test tree does not match trusted domain producer');
const policyBytes = fs.readFileSync(path.join(helperDir, 'browser-policy.json'));
const policy = JSON.parse(policyBytes);
if (record.profile?.policySha256 !== digestBytes(policyBytes) || record.image?.ref !== policy.image.ref || record.image?.digest !== policy.image.digest) throw new Error('signed execution does not use the trusted browser policy and image');
const jsonArtifact = (role) => { const p = artifact(role); return p ? JSON.parse(fs.readFileSync(p, 'utf8')) : null; };
const sha = (p) => createHash('sha256').update(fs.readFileSync(p)).digest('hex');
const aggregate = { schema: 'atd.img2threejs-metrics/v1', attestationSha256: verified.attestationSha256, dimensions: {} };
function metric(name, score, reason) {
  aggregate.dimensions[name] = score === null ? { status: 'UNAVAILABLE', reason } : { status: score >= (name === 'visual' ? 0.99 : 1) ? 'PASS' : 'FAIL', score };
  if (score !== null) fs.writeFileSync(path.join(metricRoot, `${name}.json`), JSON.stringify({ score }) + '\n', { flag: 'wx' });
}
const structure = jsonArtifact('domain_structure');
const runtime = jsonArtifact('domain_runtime');
let product = null;
const model = artifact('domain_model'), structFile = artifact('domain_structure');
if (structFile) {
  const script = path.join(helperDir, 'public-validators.py');
  const args = [script, '--product-root', productRoot, '--structure', structFile];
  if (model) args.push('--glb', model);
  const result = spawnSync('python3', args, { encoding: 'utf8', timeout: 30000, maxBuffer: 4 * 1024 * 1024 });
  if (result.status === 0) { try { product = JSON.parse(result.stdout); } catch {} }
}
aggregate.publicValidators = product;
const expected = JSON.parse(fs.readFileSync(path.join(helperDir, 'domain-config.json'), 'utf8')).expected || {};
for (const name of ['geometry', 'sceneGraph', 'materials', 'animation']) {
  const d = structure?.dimensions?.[name];
  let score = d && ['PASS', 'FAIL'].includes(d.status) && d.score === (d.status === 'PASS' ? 1 : 0) ? d.score : null;
  if (name === 'animation' && score === 1 && expected.publicRigContract === 'rig-payload.alpha') {
    if (!product || !Array.isArray(product.rig) || product.rig.length === 0) score = null;
    else if (product.rig.some((result) => result.passed !== true)) score = 0;
  }
  metric(name, score, name === 'animation' ? 'structural or public rig validation evidence unavailable' : 'structural evidence unavailable');
}
const checks = [runtime?.compiler, runtime?.browser?.load, runtime?.browser?.render, runtime?.browser?.export];
const measuredFailure = checks.some((x) => x?.status === 'FAIL');
const allMeasured = checks.every((x) => x?.status === 'PASS');
if (measuredFailure) metric('runtime', 0);
else if (runtime?.infrastructure || record.outcome === 'error' || !allMeasured || !product) metric('runtime', null, 'runtime, exported GLB, or public validator evidence unavailable');
else metric('runtime', product.glb?.status === 'PASS' ? 1 : product.glb?.status === 'FAIL' ? 0 : null, 'GLB container validation unavailable');

// Compare decoded pixels, not compressed PNG bytes. This deliberately accepts only bounded,
// noninterlaced 8-bit RGB/RGBA screenshots, and refuses unsupported formats.
function pixels(file) {
  const bytes = fs.readFileSync(file); if (bytes.length > 4 * 1024 * 1024 || !bytes.subarray(0, 8).equals(Buffer.from('89504e470d0a1a0a', 'hex'))) throw new Error('invalid PNG');
  let pos = 8, width, height, channels, ended = false; const data = [];
  while (pos + 12 <= bytes.length) {
    const n = bytes.readUInt32BE(pos), type = bytes.toString('ascii', pos + 4, pos + 8); if (n > bytes.length - pos - 12) throw new Error('invalid PNG chunk');
    const b = bytes.subarray(pos + 8, pos + 8 + n); pos += n + 12;
    if (type === 'IHDR') { if (n !== 13 || b[8] !== 8 || ![2, 6].includes(b[9]) || b[10] || b[11] || b[12]) throw new Error('unsupported PNG'); width = b.readUInt32BE(0); height = b.readUInt32BE(4); channels = b[9] === 6 ? 4 : 3; }
    if (type === 'IDAT') data.push(b); if (type === 'IEND') { ended = true; break; }
  }
  if (!ended || width !== 512 || height !== 512 || !channels) throw new Error('unexpected PNG dimensions');
  const stride = width * channels, raw = inflateSync(Buffer.concat(data), { maxOutputLength: (stride + 1) * height });
  if (raw.length !== (stride + 1) * height) throw new Error('invalid PNG data');
  const out = Buffer.alloc(stride * height);
  for (let y = 0; y < height; y++) { const filter = raw[y * (stride + 1)]; if (filter > 4) throw new Error('invalid PNG filter');
    for (let x = 0; x < stride; x++) { const i = y * stride + x, a = x >= channels ? out[i - channels] : 0, b = y ? out[i - stride] : 0, c = y && x >= channels ? out[i - stride - channels] : 0; let prediction = 0;
      if (filter === 1) prediction = a; if (filter === 2) prediction = b; if (filter === 3) prediction = Math.floor((a + b) / 2); if (filter === 4) { const p = a + b - c, pa = Math.abs(p - a), pb = Math.abs(p - b), pc = Math.abs(p - c); prediction = pa <= pb && pa <= pc ? a : pb <= pc ? b : c; }
      out[i] = (raw[y * (stride + 1) + x + 1] + prediction) & 255;
    }
  }
  return { out, channels };
}
let visualReason = 'approved external original baseline not supplied', visual = null;
try {
  if (approvalFile) {
    const approvalPath = fs.realpathSync(approvalFile), baseRoot = path.dirname(approvalPath);
    if (contained(approvalPath, path.dirname(path.dirname(evidenceRoot))) || contained(approvalPath, metricRoot)) throw new Error('approval must be outside output');
    const approval = JSON.parse(fs.readFileSync(approvalPath, 'utf8'));
    if (approval.schema !== 'atd.img2threejs-baseline-approval/v1' || approval.approved !== true || approval.mainApproved !== true || approval.terraApproved !== true || typeof approval.image !== 'string' || path.isAbsolute(approval.image)) throw new Error('baseline lacks explicit approvals');
    const base = fs.realpathSync(path.resolve(baseRoot, approval.image));
    if (!contained(base, baseRoot) || contained(base, path.dirname(path.dirname(evidenceRoot))) || contained(base, metricRoot) || sha(base) !== approval.sha256) throw new Error('baseline location or digest mismatch');
    const image = artifact('domain_beauty');
    if (!image || !runtime?.browser?.render || runtime.browser.render.status !== 'PASS') throw new Error('current screenshot unavailable');
    const provenance = { image: record.image, nodeVersion: record.nodeVersion, browserVersion: runtime.browser.version, render: runtime.browser.render.config, webglVersion: runtime.browser.render.webglVersion, renderer: runtime.browser.render.renderer };
    if (canonicalJson(approval.provenance) !== canonicalJson(provenance)) throw new Error('baseline configuration or browser provenance differs');
    const a = pixels(base), b = pixels(image); if (a.channels !== b.channels) throw new Error('PNG channels differ');
    let difference = 0; for (let i = 0; i < a.out.length; i++) difference += Math.abs(a.out[i] - b.out[i]);
    visual = 1 - difference / (a.out.length * 255);
  }
} catch (error) { visualReason = error.message; }
metric('visual', visual, visualReason);
fs.writeFileSync(path.join(metricRoot, 'domain-metrics.json'), JSON.stringify(aggregate) + '\n', { flag: 'wx' });
