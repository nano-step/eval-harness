// node-json-reporter.mjs — trusted node:test reporter. Emits one JSON document
// (atd.node-test-report/v1) that the host parses; terminal text is never interpreted.
// Runs inside the sandbox; no dependencies.
const PROPERTY_FAILURE = /^Property failed after \d+ tests?/;

function classify(error) {
  if (!error) return 'error';
  if (error.failureType === 'subtestsFailed') return 'subtests';
  const cause = error.cause;
  if (cause && (cause.code === 'ERR_ASSERTION' || cause.name === 'AssertionError')) return 'assertion';
  const message = String((cause && cause.message) || error.message || '');
  if (PROPERTY_FAILURE.test(message)) return 'property';
  return 'error';
}

export default async function* nodeJsonReporter(source) {
  const tests = [];
  let summary = null;
  for await (const event of source) {
    const d = event.data || {};
    if (event.type === 'test:pass' || event.type === 'test:fail') {
      const isSuite = d.details && d.details.type === 'suite';
      if (isSuite && event.type === 'test:pass') continue;
      const failed = event.type === 'test:fail';
      // A file that could not be loaded is reported as a nesting-0 failure named after the file.
      const fileLevel = failed && d.nesting === 0 && typeof d.name === 'string' && d.name === d.file;
      tests.push({
        name: String(d.name ?? ''), file: typeof d.file === 'string' ? d.file : null, nesting: d.nesting ?? 0,
        status: failed ? 'fail' : d.skip ? 'skip' : d.todo ? 'todo' : 'pass',
        failureKind: failed ? (fileLevel ? 'file' : classify(d.details && d.details.error)) : null,
        message: failed ? String((d.details && d.details.error && ((d.details.error.cause && d.details.error.cause.message) || d.details.error.message)) || '').slice(0, 2048) : null,
        isSuite: Boolean(isSuite),
      });
    } else if (event.type === 'test:summary' && !d.file) {
      summary = d.counts || null;
    }
  }
  yield `${JSON.stringify({ schema: 'atd.node-test-report/v1', summary, tests })}\n`;
}
