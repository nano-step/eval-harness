// exec.mjs — trusted in-container wrapper. Runs ONE framework invocation, captures bounded
// stdout/stderr into /out and exits with the framework's exit status. The framework command line is
// built here from validated argv; no value is ever passed through a shell.
//   node exec.mjs test   --framework=node:test|vitest --test-path=<abs path under /work> --test-rel=<root relative path> --test-timeout-ms=<n>
//   node exec.mjs mutate --max-mutants=<n>
// The framework runs in its own process group. When it exits, strays that inherited its pipes are
// SIGKILLed after a short bounded flush window, so an orphaned worker can never keep this wrapper (and
// therefore the container) waiting; the container then ends when this process exits.
import { spawn } from 'node:child_process';
import fs from 'node:fs';

const LOG_CAP = Number(process.env.ATD_LOG_CAP || 1048576);
const FLUSH_WINDOW_MS = 1500;
const args = Object.fromEntries(process.argv.slice(3).map((a) => { const i = a.indexOf('='); return i < 0 ? [a.slice(2), true] : [a.slice(2, i), a.slice(i + 1)]; }));
const mode = process.argv[2];

function fail(message) { process.stderr.write(`atd-exec: ${message}\n`); process.exit(97); }

function capped(file) {
  const fd = fs.openSync(file, 'w', 0o644);
  let written = 0; let truncated = false; let closed = false;
  return {
    write(chunk) {
      if (closed) return;
      if (written >= LOG_CAP) { truncated = true; return; }
      const slice = chunk.length + written > LOG_CAP ? chunk.subarray(0, LOG_CAP - written) : chunk;
      if (slice.length < chunk.length) truncated = true;
      fs.writeSync(fd, slice); written += slice.length;
    },
    close() { if (closed) return; closed = true; if (truncated) fs.writeSync(fd, '\n[atd: output truncated]\n'); fs.closeSync(fd); },
  };
}

function run(command, argv, cwd, env = process.env) {
  return new Promise((resolve) => {
    const out = capped('/out/stdout.txt'); const err = capped('/out/stderr.txt');
    const child = spawn(command, argv, { cwd, env, stdio: ['ignore', 'pipe', 'pipe'], detached: true });
    child.stdout.on('data', (c) => out.write(c));
    child.stderr.on('data', (c) => err.write(c));
    const signalGroup = (sig) => { try { process.kill(-child.pid, sig); } catch { try { child.kill(sig); } catch { /* already gone */ } } };
    process.on('SIGTERM', () => signalGroup('SIGTERM')); process.on('SIGINT', () => signalGroup('SIGINT'));
    let result = null; let done = false; let timer = null;
    const finish = () => {
      if (done) return; done = true; clearTimeout(timer);
      signalGroup('SIGKILL'); // reap any stray that kept the pipes open
      child.stdout.destroy(); child.stderr.destroy();
      out.close(); err.close();
      resolve(result ?? 1);
    };
    child.on('error', (e) => { err.write(Buffer.from(`spawn error: ${e.message}\n`)); result = 1; finish(); });
    child.on('exit', (code, signal) => {
      result = signal ? 128 + (signal === 'SIGKILL' ? 9 : 15) : (code ?? 1);
      timer = setTimeout(finish, FLUSH_WINDOW_MS);
    });
    child.on('close', finish);
  });
}

if (mode === 'test') {
  const framework = args.framework; const testPath = args['test-path']; const testRel = args['test-rel'];
  if (!testPath || !testPath.startsWith('/work/') || testPath.includes('..')) fail('invalid test path');
  if (framework === 'node:test') {
    const code = await run(process.execPath, ['--test', '--test-reporter=/atd/node-json-reporter.mjs', '--test-reporter-destination=/out/node-test.json', testPath], '/work');
    process.exit(code);
  } else if (framework === 'vitest') {
    if (!testRel || testRel.startsWith('/') || testRel.includes('..')) fail('invalid relative test path');
    const timeout = Number(args['test-timeout-ms'] || 20000);
    fs.mkdirSync('/tmp/atd', { recursive: true });
    const config = `export default ${JSON.stringify({
      root: '/work', cacheDir: '/tmp/atd/vite-cache',
      test: { include: [testRel], exclude: [], watch: false, update: false, allowOnly: false, globals: false, environment: 'node', retry: 0, testTimeout: timeout, hookTimeout: timeout, passWithNoTests: false, setupFiles: [], globalSetup: [] },
    })};\n`;
    fs.writeFileSync('/tmp/atd/vitest.config.mjs', config);
    // Vitest >= 5 publishes an API token under $XDG_DATA_HOME/vitest (fallback: <root>/node_modules/.vitest).
    // The container HOME does not exist and /work + /deps are read-only, so give Vitest a per-container
    // data dir on tmpfs. Set for the Vitest process only; the recorded container env stays the allowlist.
    fs.mkdirSync('/tmp/atd/xdg', { recursive: true });
    const code = await run(process.execPath, ['/deps/node_modules/vitest/vitest.mjs', 'run', '--config', '/tmp/atd/vitest.config.mjs', '--root', '/work', '--reporter=json', '--outputFile=/out/vitest.json'], '/work', { ...process.env, XDG_DATA_HOME: '/tmp/atd/xdg' });
    process.exit(code);
  } else fail(`unsupported framework ${framework}`);
} else if (mode === 'mutate') {
  const max = /^[0-9]+$/.test(String(args['max-mutants'] ?? '')) ? Number(args['max-mutants']) : NaN;
  if (!Number.isSafeInteger(max) || max < 1 || String(max) !== process.env.ATD_MAX_MUTANTS) fail('mutant budget missing or inconsistent with ATD_MAX_MUTANTS');
  // /src is the read-only revision export; /work is a bounded tmpfs copy Stryker may mutate.
  fs.cpSync('/src', '/work', { recursive: true, dereference: false, force: false, errorOnExist: false });
  if (!fs.existsSync('/work/node_modules') && fs.existsSync('/deps/node_modules')) {
    // A real, writable directory of symlinks into the read-only dependency mount: Vite/Vitest write
    // node_modules/.vite-temp during config loading, which a plain symlink to /deps could not allow.
    fs.mkdirSync('/work/node_modules');
    for (const name of fs.readdirSync('/deps/node_modules')) fs.symlinkSync(`/deps/node_modules/${name}`, `/work/node_modules/${name}`);
  }
  // The trusted budget reporter (official Stryker reporter plugin) is copied next to the working tree and
  // forced into the effective configuration; reporters are pinned to json + atd-budget.
  fs.copyFileSync('/atd/atd-budget-reporter.mjs', '/work/atd-budget-reporter.mjs');
  let cfg;
  try { cfg = JSON.parse(fs.readFileSync('/atd/stryker.conf.json', 'utf8')); } catch { fail('stryker config is not JSON'); }
  if (!cfg || typeof cfg !== 'object' || Array.isArray(cfg)) fail('stryker config must be an object');
  const plugins = Array.isArray(cfg.plugins) && cfg.plugins.length > 0 ? [...cfg.plugins] : ['@stryker-mutator/*'];
  if (!plugins.includes('./atd-budget-reporter.mjs')) plugins.push('./atd-budget-reporter.mjs');
  cfg.plugins = plugins;
  cfg.reporters = ['json', 'atd-budget'];
  cfg.jsonReporter = { ...(cfg.jsonReporter && typeof cfg.jsonReporter === 'object' ? cfg.jsonReporter : {}), fileName: '/out/mutation-report.json' };
  cfg.incremental = false;
  fs.writeFileSync('/work/atd.stryker.conf.json', `${JSON.stringify(cfg)}\n`);
  // The slim image has no procps; Stryker's process-tree cleanup (tree-kill) spawns `ps`. /atd/ps is a
  // trusted /proc-based stand-in (executable bit set by the controller; tmpfs is mounted noexec), put on
  // PATH for Stryker only.
  const code = await run(process.execPath, ['/deps/node_modules/@stryker-mutator/core/bin/stryker.js', 'run', '/work/atd.stryker.conf.json'], '/work', { ...process.env, PATH: `/atd:${process.env.PATH || '/usr/local/bin:/usr/bin:/bin'}` });
  process.exit(code);
} else fail(`unknown mode ${mode}`);
