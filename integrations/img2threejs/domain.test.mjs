// Trusted operator test: all helpers are overlaid with this file and bound by testsTreeSha256.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import ts from 'typescript';
import * as esbuild from 'esbuild';
import { chromium } from 'playwright-core';

const CAP = 4 * 1024 * 1024;
const config = JSON.parse(fs.readFileSync(new URL('./domain-config.json', import.meta.url), 'utf8'));
if (!config || typeof config.target !== 'string' || !/^[A-Za-z0-9_@+.-]+(?:\/[A-Za-z0-9_@+.-]+)*\.ts$/.test(config.target) || config.target.split('/').some((p) => p === '.' || p === '..')) throw new Error('invalid revision-relative target');
const target = path.join('/work', config.target);
for (const segment of config.target.split('/').reduce((paths, part) => [...paths, path.join(paths.at(-1) || '/work', part)], [])) {
  let stat; try { stat = fs.lstatSync(segment); } catch (error) { if (error.code === 'ENOENT') break; throw error; }
  if (stat.isSymbolicLink()) throw new Error('target path must not contain symlinks');
}
const output = (name, data) => {
  const bytes = Buffer.isBuffer(data) ? data : Buffer.from(JSON.stringify(data));
  if (bytes.length > CAP) throw new Error(`${name} exceeds artifact cap`);
  fs.writeFileSync(`/out/${name}`, bytes);
};

test('compile, render and export Three.js scene', async () => {
  const runtime = { schema: 'atd.img2threejs-runtime/v1', compiler: null, browser: null, infrastructure: null };
  const options = { noEmit: true, strict: true, skipLibCheck: true, target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ESNext, moduleResolution: ts.ModuleResolutionKind.Bundler, types: ['node'], typeRoots: ['/deps/node_modules/@types'] };
  const program = ts.createProgram([target], options);
  const diagnostics = ts.getPreEmitDiagnostics(program).map((d) => ({ code: d.code, category: ts.DiagnosticCategory[d.category], file: d.file ? path.relative('/work', d.file.fileName) : null, start: d.start ?? null, message: ts.flattenDiagnosticMessageText(d.messageText, '\n') }));
  const source = program.getSourceFile(target);
  const symbol = source && program.getTypeChecker().getSymbolAtLocation(source);
  if (source && (!symbol || !program.getTypeChecker().getExportsOfModule(symbol).some((entry) => entry.name === 'createScene'))) {
    diagnostics.push({ code: 'ATD_MISSING_CREATE_SCENE', category: 'Error', file: config.target, start: null, message: 'target must export createScene' });
  }
  runtime.compiler = { status: diagnostics.some((d) => d.category === 'Error') ? 'FAIL' : 'PASS', diagnostics };
  if (runtime.compiler.status === 'FAIL') { output('domain-runtime.json', runtime); assert.fail('TypeScript diagnostics'); }
  let browser, server;
  try {
    const result = await esbuild.build({ stdin: { contents: `import { evaluate } from ${JSON.stringify(new URL('./browser.mjs', import.meta.url).pathname)}; import { createScene } from ${JSON.stringify(target)}; window.domainResult = evaluate(createScene, ${JSON.stringify(config.expected || {})});`, resolveDir: '/work', sourcefile: 'domain-entry.mjs', loader: 'js' }, bundle: true, write: false, platform: 'browser', format: 'iife', nodePaths: ['/deps/node_modules'], logLevel: 'silent' });
    const bundle = result.outputFiles[0].contents;
    server = http.createServer((req, res) => { if (req.url === '/bundle.js') { res.writeHead(200, { 'content-type': 'text/javascript' }); res.end(bundle); } else if (req.url === '/') { res.writeHead(200, { 'content-type': 'text/html' }); res.end('<!doctype html><html><body><script src="/bundle.js"></script></body></html>'); } else { res.writeHead(404); res.end(); } });
    await new Promise((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve); });
    browser = await chromium.launch({ headless: true, args: ['--no-sandbox', '--use-angle=swiftshader', '--enable-unsafe-swiftshader'] });
    const context = await browser.newContext({ viewport: { width: 512, height: 512 }, deviceScaleFactor: 1 });
    const page = await context.newPage();
    await page.goto(`http://127.0.0.1:${server.address().port}/`, { waitUntil: 'load' });
    const observed = await page.evaluate(() => window.domainResult);
    runtime.browser = { version: browser.version(), ...observed.runtime };
    if (observed.structure) output('domain-structure.json', observed.structure);
    if (observed.runtime.render?.status === 'PASS') output('domain-beauty.png', await page.screenshot({ type: 'png' }));
    if (observed.glb) output('domain-model.glb', Buffer.from(observed.glb, 'base64'));
    output('domain-scene.json', { schema: 'atd.img2threejs-scene/v1', export: observed.runtime.export ?? null });
    output('domain-runtime.json', runtime);
    assert.equal(observed.runtime.load?.status, 'PASS', 'scene load');
    assert.equal(observed.runtime.render?.status, 'PASS', 'WebGL render');
    assert.equal(observed.runtime.export?.status, 'PASS', 'GLB roundtrip');
    assert.ok(observed.structure, 'structure evidence');
    for (const [dimension, result] of Object.entries(observed.structure.dimensions)) assert.equal(result.status, 'PASS', dimension);
  } catch (error) {
    // Assertions are measured defects; any other failure in the trusted producer is infrastructure.
    if (error.code !== 'ERR_ASSERTION') { runtime.infrastructure = { status: 'ERROR', error: String(error?.stack || error) }; output('domain-runtime.json', runtime); }
    throw error;
  } finally {
    if (browser) await browser.close();
    if (server) await new Promise((resolve) => server.close(resolve));
  }
});
