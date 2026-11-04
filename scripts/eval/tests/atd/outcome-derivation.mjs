// outcome-derivation.mjs — consumer-level checks of how the controller turns STRUCTURED reporter files
// (node:test JSON report, Vitest JSON reporter) plus the container exit status into pass/fail/error.
// Terminal text is never parsed; contradictory or forged reporter evidence must degrade to error.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { deriveOutcome, loadPolicy } from '../../discovery/sandbox.mjs';

const { policy } = loadPolicy();
const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'atd-derive-'));
let failures = 0;
const check = (name, cond, extra = '') => { console.log(`  ${cond ? 'ok ' : 'FAIL'} - ${name}${cond ? '' : ` ${extra}`}`); if (!cond) failures += 1; };

const FILE = '/work/tests/t.test.ts';
const NODE_FILE = '/work/tests/t.test.mjs';
const clean = { exitCode: 0, timedOut: false, oomKilled: false };
function derive(framework, report, run = clean, expectedFile = framework === 'vitest' ? FILE : NODE_FILE, raw = null) {
  const p = path.join(dir, `${framework}-${Math.random().toString(36).slice(2)}.json`);
  if (raw !== null) fs.writeFileSync(p, raw); else if (report !== undefined) fs.writeFileSync(p, JSON.stringify(report));
  return deriveOutcome({ framework, run, reporterPath: p, expectedFile, policy });
}
const vt = (cases, status = 'passed', name = FILE) => ({ numTotalTests: cases.length, testResults: [{ name, status, assertionResults: cases }] });
const vcase = (status, msg) => ({ status, title: 't', fullName: 't', failureMessages: msg ? [msg] : [] });
const nt = (tests) => ({ schema: 'atd.node-test-report/v1', summary: null, tests: tests.map((t) => ({ name: 't', file: NODE_FILE, nesting: 0, message: null, isSuite: false, failureKind: null, ...t })) });

console.log('== vitest JSON reporter ==');
let r = derive('vitest', vt([vcase('passed'), vcase('passed')]));
check('all passed, exit 0 => pass', r.outcome === 'pass' && r.counts.executed === 2, JSON.stringify(r));
r = derive('vitest', vt([vcase('passed'), vcase('failed', 'AssertionError: expected 9 to be 10 // Object.is equality\n    at x')], 'failed'), { ...clean, exitCode: 1 });
check('assertion failure, exit 1 => fail', r.outcome === 'fail' && r.counts.assertionFailures === 1, JSON.stringify(r));
r = derive('vitest', vt([vcase('failed', 'Error: Property failed after 3 tests\n{ seed: 7, path: "2:0" }\nCounterexample: [10,0,10]\nShrunk 4 time(s)')], 'failed'), { ...clean, exitCode: 1 });
check('fast-check property failure => fail with counterexample', r.outcome === 'fail' && /Counterexample/.test(r.counterexample || ''), JSON.stringify(r));
r = derive('vitest', vt([vcase('failed', 'TypeError: clamp is not a function\n    at x')], 'failed'), { ...clean, exitCode: 1 });
check('non-assertion exception => error/runtime_error (never a finding)', r.outcome === 'error' && r.errorClass === 'runtime_error', JSON.stringify(r));
r = derive('vitest', vt([], 'failed'), { ...clean, exitCode: 1 });
check('file failed during collection (syntax/import error) => error/compile', r.outcome === 'error' && r.errorClass === 'compile', JSON.stringify(r));
r = derive('vitest', vt([vcase('failed', 'AssertionError: forged')], 'failed'), clean);
check('forged: assertion failure reported but exit code 0 => error/infra', r.outcome === 'error' && r.errorClass === 'infra', JSON.stringify(r));
r = derive('vitest', vt([vcase('passed')], 'passed'), { ...clean, exitCode: 1 });
check('forged: all passed but exit code 1 => error/infra', r.outcome === 'error' && r.errorClass === 'infra', JSON.stringify(r));
r = derive('vitest', vt([vcase('skipped'), vcase('pending')]));
check('only skipped tests => error/no_tests_collected', r.outcome === 'error' && r.errorClass === 'no_tests_collected', JSON.stringify(r));
r = derive('vitest', { testResults: [] });
check('no test file collected => error/no_tests_collected', r.outcome === 'error' && r.errorClass === 'no_tests_collected', JSON.stringify(r));
r = derive('vitest', vt([vcase('passed')], 'passed', '/work/tests/other.test.ts'));
check('report about a different file => error/infra', r.outcome === 'error' && r.errorClass === 'infra', JSON.stringify(r));
r = derive('vitest', vt([vcase('passed')], 'failed'), { ...clean, exitCode: 1 });
check('suite-level failure after passing cases => error', r.outcome === 'error', JSON.stringify(r));
r = derive('vitest', undefined);
check('reporter file absent => error/infra', r.outcome === 'error' && r.errorClass === 'infra', JSON.stringify(r));
r = derive('vitest', undefined, clean, FILE, '{not json');
check('reporter file not JSON => error/infra', r.outcome === 'error' && r.errorClass === 'infra', JSON.stringify(r));
r = derive('vitest', undefined, clean, FILE, `{"pad":"${'x'.repeat(policy.limits.maxReporterBytes + 10)}"}`);
check('oversized reporter file => error/infra', r.outcome === 'error' && r.errorClass === 'infra', JSON.stringify(r));
r = derive('vitest', vt([vcase('passed')]), { ...clean, timedOut: true });
check('host deadline => error/timeout even if a pass report exists', r.outcome === 'error' && r.errorClass === 'timeout', JSON.stringify(r));
r = derive('vitest', vt([vcase('passed')]), { ...clean, exitCode: 137, oomKilled: true });
check('OOM kill => error/oom', r.outcome === 'error' && r.errorClass === 'oom', JSON.stringify(r));
r = derive('vitest', vt([vcase('failed', 'AssertionError: expected false to be true'), vcase('failed', 'TypeError: cannot read property of undefined')], 'failed'), { ...clean, exitCode: 1 });
check('mixed assertion + TypeError in one file => error/runtime_error, all counts retained (never fail)', r.outcome === 'error' && r.errorClass === 'runtime_error' && r.counts.failed === 2 && r.counts.assertionFailures === 1 && r.counts.otherFailures === 1, JSON.stringify(r));
const hookReport = vt([vcase('passed'), vcase('failed', 'AssertionError: expected 1 to be 2')], 'failed'); hookReport.testResults[0].message = 'Error: afterAll hook failed';
r = derive('vitest', hookReport, { ...clean, exitCode: 1 });
check('assertion failure plus a file-level hook/unhandled error => error/runtime_error', r.outcome === 'error' && r.errorClass === 'runtime_error' && r.counts.assertionFailures === 1, JSON.stringify(r));

console.log('== node:test JSON report ==');
r = derive('node:test', nt([{ status: 'pass' }, { status: 'pass' }]));
check('all passed => pass', r.outcome === 'pass', JSON.stringify(r));
r = derive('node:test', nt([{ status: 'pass' }, { status: 'fail', failureKind: 'assertion', message: '9 !== 10' }]), { ...clean, exitCode: 1 });
check('assertion failure => fail', r.outcome === 'fail', JSON.stringify(r));
r = derive('node:test', nt([{ status: 'fail', failureKind: 'property', message: 'Property failed after 2 tests\nCounterexample: [10,0,10]' }]), { ...clean, exitCode: 1 });
check('property failure => fail with counterexample', r.outcome === 'fail' && Boolean(r.counterexample), JSON.stringify(r));
r = derive('node:test', nt([{ status: 'fail', failureKind: 'error', message: 'Cannot read properties of null' }]), { ...clean, exitCode: 1 });
check('TypeError in test => error/runtime_error', r.outcome === 'error' && r.errorClass === 'runtime_error', JSON.stringify(r));
r = derive('node:test', nt([{ status: 'fail', failureKind: 'file', name: NODE_FILE }]), { ...clean, exitCode: 1 });
check('file-level failure (import/syntax) => error/compile', r.outcome === 'error' && r.errorClass === 'compile', JSON.stringify(r));
r = derive('node:test', nt([{ status: 'skip' }, { status: 'todo' }]));
check('only skip/todo => error/no_tests_collected', r.outcome === 'error' && r.errorClass === 'no_tests_collected', JSON.stringify(r));
r = derive('node:test', nt([{ status: 'fail', failureKind: 'subtests', message: 'subtests failed' }, { status: 'fail', failureKind: 'assertion', name: 'inner' }]), { ...clean, exitCode: 1 });
check('parent "subtests failed" is not double counted', r.outcome === 'fail' && r.counts.failed === 1, JSON.stringify(r));
r = derive('node:test', nt([{ status: 'pass', file: '/work/tests/other.test.mjs' }]));
check('report about a different file => error/infra', r.outcome === 'error' && r.errorClass === 'infra', JSON.stringify(r));
r = derive('node:test', { schema: 'something-else', tests: [] });
check('wrong report schema => error/infra', r.outcome === 'error' && r.errorClass === 'infra', JSON.stringify(r));
r = derive('node:test', nt([{ status: 'fail', failureKind: 'assertion', message: '9 !== 10' }, { status: 'fail', failureKind: 'error', message: 'Cannot read properties of undefined' }]), { ...clean, exitCode: 1 });
check('mixed assertion + runtime failure => error/runtime_error with both counted (never fail)', r.outcome === 'error' && r.errorClass === 'runtime_error' && r.counts.failed === 2 && r.counts.assertionFailures === 1 && r.counts.otherFailures === 1, JSON.stringify(r));

fs.rmSync(dir, { recursive: true, force: true });
process.exit(failures === 0 ? 0 : 1);
