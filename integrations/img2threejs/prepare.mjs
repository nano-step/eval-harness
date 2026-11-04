#!/usr/bin/env node
// Materialize trusted test inputs in a fresh case workdir. No target code is imported here.
import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const [workdir, repository, commit, dependencies] = process.argv.slice(2);
if (!workdir || !repository || !/^[0-9a-f]{40}$/.test(commit || '') || !dependencies || ![workdir, repository, dependencies].every(path.isAbsolute)) {
  throw new Error('usage: node prepare.mjs ABS_EMPTY_WORKDIR ABS_REPOSITORY COMMIT ABS_DEPS');
}
if (fs.readdirSync(workdir).length) throw new Error('workdir must be empty');
const tests = path.join(workdir, 'tests'); fs.mkdirSync(tests);
for (const name of ['domain.test.mjs', 'browser.mjs', 'structure.mjs', 'domain-config.json']) fs.copyFileSync(path.join(here, name), path.join(tests, name), fs.constants.COPYFILE_EXCL);
const entry = fs.readFileSync(path.join(tests, 'domain.test.mjs'));
const testSha256 = createHash('sha256').update(entry).digest('hex');
fs.writeFileSync(path.join(workdir, 'candidate.json'), JSON.stringify({ schema: 'atd.test-candidate/v1', id: 'img2threejs-domain', trust: 'untrusted', framework: 'node:test', testFile: 'domain.test.mjs', testSha256 }) + '\n', { flag: 'wx' });
const runner = { repository, baseCommit: commit, candidateCommit: commit, candidateFile: 'candidate.json', testsDir: 'tests', testsRel: '.', dependencies, timeoutSeconds: 120 };
process.stdout.write(JSON.stringify(runner) + '\n');
