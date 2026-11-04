#!/usr/bin/env node
// Scoped mutation-testing support built on the maintained StrykerJS tool.
//  - config: derive a Stryker configuration restricted to the changed ranges/functions of a
//    change-risk report, with deterministic seeds and a non-in-place sandbox copy of the sources.
//  - report: normalize a Stryker JSON report into atd.mutation-report/v1 with explicit
//    killed / survived / equivalent / invalid semantics.
//  - compare: show which surviving mutants a later run now kills.
// There is NO custom mutation engine and this module NEVER spawns Stryker or any test code:
// execution happens only inside the confined sandbox that runs plan.argv. Surviving mutants are
// test-suite GAPS (hypotheses); only differential execution evidence can confirm a product bug.
import path from 'node:path';
import {
  DiscoveryError, canonicalSha256, canonicalize, checkSafeRelativePath, loadSchema, parseFlags, readBlob, readJsonFile,
  requireFlags, runCli, sha256, validateSchema, writeJsonFile,
  isMain,
} from './generation-util.mjs';
import { comparableTokens, lex } from './generation-lexer.mjs';
import { validateChangeRisk } from './risk.mjs';
import fs from 'node:fs';

const FRAMEWORKS = ['vitest', 'node:test'];
const TEST_FILE_RE = /\.(?:test|spec)\.[cm]?[jt]sx?$/;
const MAX_TESTS = 100;
const MAX_FILES_IN_REPORT = 2000;
const MAX_MUTANTS_IN_REPORT = 20000;
const MAX_LISTED_MUTANTS = 5000;
const MAX_GAPS = 500;
const MAX_TEXT = 200;
const STRYKER_ENTRY = 'node_modules/@stryker-mutator/core/bin/stryker.js';
const REPORT_FILE = 'reports/mutation/mutation.json';
const MUTATOR_NAME_RE = /^[A-Za-z]{1,64}$/;
export const DEFAULT_MAX_MUTANTS = 100;
export const HARD_MAX_MUTANTS = 500;
export const BUDGET_REPORTER_NAME = 'atd-budget';
export const BUDGET_REPORTER_PLUGIN = './atd-budget-reporter.mjs';

export const SEMANTICS = Object.freeze({
  killed: 'A test failed or timed out on the mutant: the existing tests detect this behavior change.',
  survived: 'No test failed (or none covers the code): a TEST-SUITE GAP hypothesis. It is NOT evidence of a product defect.',
  equivalent: 'The mutant is behavior-preserving (identical replacement or reviewer-marked). Excluded from the score and from gaps.',
  invalid: 'The mutant did not compile or crashed the runner. Excluded from the score and from gaps.',
  ignored: 'Excluded by configuration. Excluded from the score and from gaps.',
  unknown: 'Status could not be attributed (pending, unrecognized, out-of-scope or source mismatch). Excluded from the score and from gaps.',
  confirmedBug: 'Never produced by mutation testing. Only differential evidence (base passes, candidate fails, supported by the specification and stable across samples) can confirm a defect.',
});

/** Deterministic seed derived from the evaluated diff; recorded and injected as ATD_SEED/FC_SEED. */
export function deriveSeed(diffSha256) {
  if (typeof diffSha256 !== 'string' || !/^[0-9a-f]{64}$/.test(diffSha256)) throw new DiscoveryError('usage', 'diffSha256 must be a 64-hex SHA-256');
  return parseInt(sha256(`atd-seed:${diffSha256}`).slice(0, 8), 16) & 0x7fffffff;
}

function mergeRanges(ranges) {
  const sorted = [...ranges].sort((a, b) => a.startLine - b.startLine || a.endLine - b.endLine);
  const out = [];
  for (const r of sorted) {
    const last = out[out.length - 1];
    if (last && r.startLine <= last.endLine + 1) last.endLine = Math.max(last.endLine, r.endLine);
    else out.push({ startLine: r.startLine, endLine: r.endLine });
  }
  return out;
}

// ---------------------------------------------------------------------------
// Plan / config
// ---------------------------------------------------------------------------
/**
 * @param {{riskReport:object, framework:'vitest'|'node:test', tests?:string[], seed?:number, scope?:'hunks'|'symbols',
 *          vitestConfigFile?:string, typescriptChecker?:boolean, tsconfigFile?:string, excludedMutations?:string[],
 *          timeoutMS?:number, concurrency?:number, maxMutants?:number}} opts
 */
export function createMutationPlan(opts) {
  if (!opts || typeof opts !== 'object') throw new DiscoveryError('usage', 'createMutationPlan requires an options object');
  const { riskReport, framework, tests = [], scope = 'hunks', vitestConfigFile, typescriptChecker = false, tsconfigFile, excludedMutations = [] } = opts;
  const problems = riskReport ? validateChangeRisk(riskReport) : [{ path: '$', message: 'riskReport is required' }];
  if (problems.length > 0) throw new DiscoveryError('invalid_risk_report', `riskReport is invalid: ${problems[0].path} ${problems[0].message}`);
  if (!FRAMEWORKS.includes(framework)) throw new DiscoveryError('usage', 'framework must be vitest or node:test');
  if (scope !== 'hunks' && scope !== 'symbols') throw new DiscoveryError('usage', "scope must be 'hunks' or 'symbols'");
  if (riskReport.targets.length === 0) throw new DiscoveryError('no_targets', 'the change-risk report has no targets: there is nothing to mutate');
  const seed = opts.seed === undefined ? deriveSeed(riskReport.diffSha256) : opts.seed;
  if (!Number.isInteger(seed) || seed < 0 || seed > 2147483647) throw new DiscoveryError('usage', 'seed must be an integer in [0, 2147483647]');
  const timeoutMS = opts.timeoutMS === undefined ? 5000 : opts.timeoutMS;
  const concurrency = opts.concurrency === undefined ? 1 : opts.concurrency;
  const maxMutants = opts.maxMutants === undefined ? DEFAULT_MAX_MUTANTS : opts.maxMutants;
  if (!Number.isInteger(maxMutants) || maxMutants < 1 || maxMutants > HARD_MAX_MUTANTS) {
    throw new DiscoveryError('usage', `maxMutants must be an integer in [1, ${HARD_MAX_MUTANTS}]`);
  }
  if (!Number.isInteger(timeoutMS) || timeoutMS < 500 || timeoutMS > 60000) throw new DiscoveryError('usage', 'timeoutMS must be an integer in [500, 60000]');
  if (!Number.isInteger(concurrency) || concurrency < 1 || concurrency > 4) throw new DiscoveryError('usage', 'concurrency must be an integer in [1, 4]');
  if (!Array.isArray(tests) || tests.length > MAX_TESTS) throw new DiscoveryError('usage', `tests must be an array of at most ${MAX_TESTS} paths`);
  for (const t of tests) {
    const p = checkSafeRelativePath(t);
    if (p) throw new DiscoveryError('unsafe_path', `test path ${JSON.stringify(t)}: ${p}`);
    if (!TEST_FILE_RE.test(t)) throw new DiscoveryError('unsafe_path', `test path ${JSON.stringify(t)} must end in .test.<ext> or .spec.<ext>`);
  }
  if (framework === 'node:test' && tests.length === 0) throw new DiscoveryError('usage', 'node:test requires at least one test path');
  if (!Array.isArray(excludedMutations) || excludedMutations.some((m) => typeof m !== 'string' || !MUTATOR_NAME_RE.test(m))) {
    throw new DiscoveryError('usage', 'excludedMutations must be Stryker mutator names (letters only)');
  }
  for (const [name, value] of [['vitestConfigFile', vitestConfigFile], ['tsconfigFile', tsconfigFile]]) {
    if (value !== undefined) {
      const p = checkSafeRelativePath(value);
      if (p) throw new DiscoveryError('unsafe_path', `${name}: ${p}`);
    }
  }

  const files = [];
  const mutate = [];
  for (const target of riskReport.targets) {
    const problem = checkSafeRelativePath(target.file);
    if (problem) throw new DiscoveryError('unsafe_path', `target ${JSON.stringify(target.file)}: ${problem}`);
    let ranges = target.hunks.map((h) => ({ startLine: h.startLine, endLine: h.endLine }));
    if (scope === 'symbols' && target.symbolRanges && target.symbolRanges.length > 0) {
      ranges = [...target.symbolRanges.map((s) => ({ startLine: s.startLine, endLine: s.endLine })), ...ranges];
    }
    ranges = mergeRanges(ranges);
    files.push({ file: target.file, symbols: target.symbols, ranges });
    for (const r of ranges) mutate.push(`${target.file}:${r.startLine}-${r.endLine}`);
  }

  const config = {
    mutate,
    testRunner: framework === 'vitest' ? 'vitest' : 'command',
    plugins: framework === 'vitest' ? ['@stryker-mutator/vitest-runner', BUDGET_REPORTER_PLUGIN] : [BUDGET_REPORTER_PLUGIN],
    coverageAnalysis: framework === 'vitest' ? 'perTest' : 'off',
    checkers: [],
    reporters: ['json', BUDGET_REPORTER_NAME],
    jsonReporter: { fileName: REPORT_FILE },
    inPlace: false,
    tempDirName: '.stryker-tmp',
    cleanTempDir: true,
    incremental: false,
    dryRunOnly: false,
    concurrency,
    timeoutMS,
    timeoutFactor: 1.5,
    ignorePatterns: ['.git', 'reports', 'atd-out', '.stryker-tmp'],
    allowConsoleColors: false,
    logLevel: 'warn',
    fileLogLevel: 'off',
    thresholds: { high: 80, low: 60, break: null },
  };
  if (framework === 'node:test') config.commandRunner = { command: `node --test ${tests.join(' ')}` };
  if (framework === 'vitest' && vitestConfigFile) config.vitest = { configFile: vitestConfigFile };
  if (typescriptChecker) {
    config.checkers = ['typescript'];
    config.plugins = [...config.plugins, '@stryker-mutator/typescript-checker'];
    if (tsconfigFile) config.tsconfigFile = tsconfigFile;
  }
  if (excludedMutations.length > 0) config.mutator = { excludedMutations: [...excludedMutations].sort() };

  const plan = {
    schema: 'atd.mutation-plan/v1',
    baseCommit: riskReport.baseCommit,
    candidateCommit: riskReport.candidateCommit,
    diffSha256: riskReport.diffSha256,
    scope,
    seed,
    maxMutants,
    env: { ATD_SEED: String(seed), FC_SEED: String(seed) },
    framework,
    tests: [...tests],
    files,
    strykerConfig: canonicalize(config),
    configSha256: canonicalSha256(config),
    reportPath: REPORT_FILE,
    argv: ['node', STRYKER_ENTRY, 'run', 'stryker.config.json'],
    requiresConfinement: true,
    hostExecution: 'forbidden',
    notes: [
      'Run plan.argv only inside the confined atd-sandbox against an exported copy of the candidate revision plus the generated tests.',
      'inPlace=false makes Stryker mutate a sandbox copy; the exported sources must stay byte-identical (verified by the report command).',
      'Stryker has no seed option: mutant order is deterministic and tests receive ATD_SEED/FC_SEED from plan.env.',
      'plan.maxMutants bounds the planned mutants per run: the trusted atd-budget reporter (plugin ./atd-budget-reporter.mjs, copied into the work tree by the sandbox runner) must abort Stryker before any mutant is tested when the plan exceeds it. Scope and timeout alone do not bound the mutant count.',
    ],
  };
  const bad = validateSchema(loadSchema('atd.mutation-plan.v1.json'), plan);
  if (bad.length > 0) throw new DiscoveryError('invalid_plan', `internal: plan violates schema: ${bad[0].path} ${bad[0].message}`);
  return plan;
}

/** Write stryker.config.json (pure Stryker config) and mutation-plan.json into outDir. */
export function writePlanFiles(plan, outDir) {
  fs.mkdirSync(outDir, { recursive: true });
  const configPath = path.join(outDir, 'stryker.config.json');
  const planPath = path.join(outDir, 'mutation-plan.json');
  for (const p of [configPath, planPath]) {
    let st = null;
    try { st = fs.lstatSync(p); } catch { /* absent */ }
    if (st && st.isSymbolicLink()) throw new DiscoveryError('unsafe_output', `refusing to write through symlink ${p}`);
  }
  fs.writeFileSync(configPath, `${JSON.stringify(plan.strykerConfig, null, 2)}\n`, { mode: 0o644 });
  writeJsonFile(planPath, plan);
  return { configPath, planPath };
}

// ---------------------------------------------------------------------------
// Report normalization
// ---------------------------------------------------------------------------
const STATUS_OUTCOME = {
  Killed: ['killed', 'killed'],
  Timeout: ['killed', 'timeout'],
  Survived: ['survived', 'survived'],
  NoCoverage: ['survived', 'no_coverage'],
  CompileError: ['invalid', 'compile_error'],
  RuntimeError: ['invalid', 'runtime_error'],
  Ignored: ['ignored', 'ignored'],
  Pending: ['unknown', 'pending'],
};

const cut = (s, n = MAX_TEXT) => (typeof s === 'string' && s.length > n ? `${s.slice(0, n - 1)}…` : String(s ?? ''));

function normalizePath(file) {
  return String(file).replace(/\\/g, '/').replace(/^\.\//, '');
}

function sliceSource(lines, loc) {
  const { start, end } = loc;
  if (!start || !end || !Number.isInteger(start.line) || !Number.isInteger(end.line)) return null;
  if (start.line < 1 || end.line > lines.length || end.line < start.line) return null;
  if (start.line === end.line) return lines[start.line - 1].slice(start.column - 1, end.column - 1);
  const parts = [lines[start.line - 1].slice(start.column - 1)];
  for (let l = start.line + 1; l < end.line; l++) parts.push(lines[l - 1]);
  parts.push(lines[end.line - 1].slice(0, end.column - 1));
  return parts.join('\n');
}

function sameCode(a, b) {
  if (a === b) return true;
  const la = lex(a);
  const lb = lex(b);
  if (!la.ok || !lb.ok) return false;
  const ka = comparableTokens(la.tokens).map((k) => k.key);
  const kb = comparableTokens(lb.tokens).map((k) => k.key);
  return ka.length === kb.length && ka.every((k, i) => k === kb[i]);
}

function rangeOverlaps(ranges, start, end) {
  return ranges.some((r) => start <= r.endLine && end >= r.startLine);
}

/**
 * Normalize a Stryker JSON report (mutation-testing-report-schema) into atd.mutation-report/v1.
 * @param {object} raw parsed Stryker JSON report
 * @param {{riskReport?:object, plan?:object, repository?:string, candidateCommit?:string, equivalent?:string[]}} [ctx]
 */
export function normalizeStrykerReport(raw, ctx = {}) {
  if (!raw || typeof raw !== 'object' || typeof raw.files !== 'object' || raw.files === null || Array.isArray(raw.files)) {
    throw new DiscoveryError('invalid_report', 'not a Stryker mutation report: "files" object is missing');
  }
  const fileNames = Object.keys(raw.files);
  if (fileNames.length > MAX_FILES_IN_REPORT) throw new DiscoveryError('invalid_report', `report lists more than ${MAX_FILES_IN_REPORT} files`);
  const { riskReport = null, plan = null, repository, candidateCommit } = ctx;
  if (riskReport) {
    const problems = validateChangeRisk(riskReport);
    if (problems.length > 0) throw new DiscoveryError('invalid_risk_report', `riskReport is invalid: ${problems[0].path} ${problems[0].message}`);
  }
  if (plan && riskReport && plan.diffSha256 !== riskReport.diffSha256) throw new DiscoveryError('provenance_mismatch', 'plan and riskReport describe different diffs');
  const commit = candidateCommit || (riskReport ? riskReport.candidateCommit : null);
  if (repository && !commit) throw new DiscoveryError('usage', 'candidateCommit (or riskReport) is required to verify sources against a repository');
  if (riskReport && candidateCommit && candidateCommit !== riskReport.candidateCommit) throw new DiscoveryError('provenance_mismatch', 'candidateCommit differs from riskReport.candidateCommit');
  const equivalentIds = new Set(ctx.equivalent || []);

  const scopeFiles = plan ? plan.files : riskReport ? riskReport.targets.map((t) => ({ file: t.file, ranges: t.hunks })) : null;
  const scopeMap = scopeFiles ? new Map(scopeFiles.map((f) => [f.file, f.ranges])) : null;
  const symbolMap = riskReport ? new Map(riskReport.targets.map((t) => [t.file, t.symbolRanges || []])) : new Map();

  const sources = [];
  const mutants = [];
  const warnings = [];
  let total = 0;
  for (const rawName of fileNames.sort()) {
    const file = normalizePath(rawName);
    const entry = raw.files[rawName];
    if (!entry || typeof entry !== 'object' || !Array.isArray(entry.mutants)) { warnings.push(`file ${file}: malformed entry ignored`); continue; }
    total += entry.mutants.length;
    if (total > MAX_MUTANTS_IN_REPORT) throw new DiscoveryError('invalid_report', `report lists more than ${MAX_MUTANTS_IN_REPORT} mutants`);
    const inScopeFile = scopeMap ? scopeMap.has(file) : true;
    const source = typeof entry.source === 'string' ? entry.source : null;
    let sourceOk = null;
    if (source !== null && repository && commit) {
      const blob = readBlob(repository, commit, file);
      const candSha = blob ? sha256(blob) : null;
      sourceOk = candSha !== null && candSha === sha256(Buffer.from(source, 'utf8'));
      sources.push({ file, reportSha256: sha256(Buffer.from(source, 'utf8')), candidateSha256: candSha, matches: sourceOk });
      if (!sourceOk) warnings.push(`file ${file}: embedded source differs from candidate ${commit}; its mutants are excluded`);
    } else if (source !== null) {
      sources.push({ file, reportSha256: sha256(Buffer.from(source, 'utf8')), candidateSha256: null, matches: null });
    }
    const lines = source === null ? null : source.split(/\r\n|[\n\r]/);
    const ranges = scopeMap ? scopeMap.get(file) || [] : null;
    for (const m of entry.mutants) {
      if (!m || typeof m !== 'object' || !m.location || !m.location.start || !m.location.end) continue;
      const startLine = m.location.start.line;
      const endLine = m.location.end.line;
      if (!Number.isInteger(startLine) || !Number.isInteger(endLine) || startLine < 1 || endLine < startLine) continue;
      const mapping = STATUS_OUTCOME[m.status] || ['unknown', 'unrecognized'];
      let outcome = mapping[0];
      let detail = mapping[1];
      const replacement = String(m.replacement ?? '');
      const original = lines ? sliceSource(lines, m.location) : null;
      const key = `${file}|${cut(m.mutatorName, 64)}|${startLine}:${m.location.start.column}-${endLine}:${m.location.end.column}|${replacement}`;
      const id = String(m.id);
      if (!inScopeFile || (ranges && !rangeOverlaps(ranges, startLine, endLine))) {
        outcome = 'unknown';
        detail = 'out_of_scope';
      } else if (sourceOk === false) {
        outcome = 'unknown';
        detail = 'source_mismatch';
      } else if (outcome === 'survived') {
        if (equivalentIds.has(id) || equivalentIds.has(key)) { outcome = 'equivalent'; detail = 'reviewed'; }
        else if (original !== null && sameCode(original, replacement)) { outcome = 'equivalent'; detail = 'identical_replacement'; }
      }
      const symbolRange = (symbolMap.get(file) || [])
        .filter((s) => s.startLine <= startLine && s.endLine >= startLine)
        .sort((a, b) => (a.endLine - a.startLine) - (b.endLine - b.startLine))[0];
      mutants.push({
        id,
        key,
        file,
        mutator: cut(m.mutatorName, 64),
        startLine,
        startColumn: m.location.start.column,
        endLine,
        endColumn: m.location.end.column,
        replacement: cut(replacement),
        original: original === null ? null : cut(original),
        symbol: symbolRange ? symbolRange.name : null,
        status: String(m.status),
        outcome,
        detail,
      });
    }
  }
  mutants.sort((a, b) => (a.file < b.file ? -1 : a.file > b.file ? 1 : a.startLine - b.startLine || a.startColumn - b.startColumn || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0)));

  const counts = { total: mutants.length, killed: 0, survived: 0, equivalent: 0, invalid: 0, ignored: 0, unknown: 0, noCoverage: 0, timeout: 0 };
  for (const m of mutants) {
    counts[m.outcome] += 1;
    if (m.detail === 'no_coverage') counts.noCoverage += 1;
    if (m.detail === 'timeout') counts.timeout += 1;
  }
  const denominator = counts.killed + counts.survived;
  const gaps = mutants.filter((m) => m.outcome === 'survived').slice(0, MAX_GAPS).map((m) => ({
    id: m.id,
    key: m.key,
    file: m.file,
    startLine: m.startLine,
    startColumn: m.startColumn,
    endLine: m.endLine,
    endColumn: m.endColumn,
    mutator: m.mutator,
    replacement: m.replacement,
    original: m.original,
    symbol: m.symbol,
    subtype: m.detail === 'no_coverage' ? 'no_coverage' : 'survived',
    kind: 'surviving_gap',
    confirmedBug: false,
  }));
  const framework = raw.framework && typeof raw.framework === 'object' ? raw.framework : {};
  const report = {
    schema: 'atd.mutation-report/v1',
    tool: {
      name: 'stryker',
      version: typeof framework.version === 'string' ? framework.version : null,
      reportSchemaVersion: raw.schemaVersion === undefined ? null : String(raw.schemaVersion),
    },
    baseCommit: riskReport ? riskReport.baseCommit : null,
    candidateCommit: commit || null,
    diffSha256: riskReport ? riskReport.diffSha256 : null,
    riskReportSha256: riskReport ? canonicalSha256(riskReport) : null,
    seed: plan ? plan.seed : null,
    configSha256: plan ? plan.configSha256 : null,
    scope: plan ? plan.scope : null,
    sources,
    sourcePreserved: sources.length > 0 && sources.every((s) => s.matches !== null) ? sources.every((s) => s.matches === true) : null,
    counts,
    score: denominator === 0 ? null : Math.round((counts.killed / denominator) * 10000) / 10000,
    mutants: mutants.slice(0, MAX_LISTED_MUTANTS),
    mutantsTruncated: mutants.length > MAX_LISTED_MUTANTS,
    gaps,
    gapsTruncated: counts.survived > MAX_GAPS,
    semantics: { ...SEMANTICS },
    warnings,
  };
  const bad = validateSchema(loadSchema('atd.mutation-report.v1.json'), report);
  if (bad.length > 0) throw new DiscoveryError('invalid_report', `internal: report violates schema: ${bad[0].path} ${bad[0].message}`);
  return report;
}

// ---------------------------------------------------------------------------
// Run comparison (e.g. baseline tests vs baseline + generated tests)
// ---------------------------------------------------------------------------
export function compareMutationRuns(before, after) {
  for (const [name, r] of [['before', before], ['after', after]]) {
    if (!r || r.schema !== 'atd.mutation-report/v1') throw new DiscoveryError('invalid_report', `${name} is not an atd.mutation-report/v1`);
  }
  if (before.candidateCommit && after.candidateCommit && before.candidateCommit !== after.candidateCommit) throw new DiscoveryError('provenance_mismatch', 'runs mutate different candidate revisions');
  if (before.diffSha256 && after.diffSha256 && before.diffSha256 !== after.diffSha256) throw new DiscoveryError('provenance_mismatch', 'runs describe different diffs');
  if (before.configSha256 && after.configSha256 && before.configSha256 !== after.configSha256) throw new DiscoveryError('provenance_mismatch', 'runs used different Stryker configurations (scope differs)');
  if (before.sourcePreserved === false || after.sourcePreserved === false) throw new DiscoveryError('source_mismatch', 'a run did not preserve the candidate sources; comparison refused');
  const index = (r) => new Map(r.mutants.map((m) => [m.key, m]));
  const b = index(before);
  const a = index(after);
  const killedNow = [];
  const stillSurviving = [];
  const newlySurvived = [];
  const onlyBefore = [];
  const onlyAfter = [];
  for (const [key, mb] of b) {
    const ma = a.get(key);
    if (!ma) { onlyBefore.push(key); continue; }
    if (mb.outcome === 'survived' && ma.outcome === 'killed') killedNow.push({ key, beforeId: mb.id, afterId: ma.id, file: mb.file, startLine: mb.startLine, mutator: mb.mutator, replacement: mb.replacement });
    else if (mb.outcome === 'survived' && ma.outcome === 'survived') stillSurviving.push({ key, id: ma.id, file: ma.file, startLine: ma.startLine, mutator: ma.mutator, replacement: ma.replacement });
    else if (mb.outcome === 'killed' && ma.outcome === 'survived') newlySurvived.push({ key, id: ma.id, file: ma.file, startLine: ma.startLine, mutator: ma.mutator, replacement: ma.replacement });
  }
  for (const key of a.keys()) if (!b.has(key)) onlyAfter.push(key);
  const byKey = (x, y) => (x.key < y.key ? -1 : x.key > y.key ? 1 : 0);
  killedNow.sort(byKey);
  stillSurviving.sort(byKey);
  newlySurvived.sort(byKey);
  return {
    schema: 'atd.mutation-comparison/v1',
    before: { score: before.score, counts: before.counts },
    after: { score: after.score, counts: after.counts },
    scoreDelta: before.score === null || after.score === null ? null : Math.round((after.score - before.score) * 10000) / 10000,
    killedNow,
    stillSurviving,
    newlySurvived,
    onlyBefore: onlyBefore.sort(),
    onlyAfter: onlyAfter.sort(),
    note: 'killedNow lists mutants that survived the first run and are killed by the second: evidence the added tests close a test-suite gap, not evidence of a product defect.',
  };
}

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------
const HELP = `Usage: mutation.mjs <command> [flags]

Scoped mutation testing on the maintained Stryker. This tool NEVER runs Stryker or any tests;
the generated plan.argv must be executed inside the confined atd-sandbox only.

Commands:
  config   --risk=FILE --framework=vitest|node:test --out-dir=DIR [--tests=a.test.js,b.test.js]
           [--seed=N] [--scope=hunks|symbols] [--vitest-config=FILE] [--typescript-checker]
           [--tsconfig=FILE] [--exclude-mutations=A,B] [--timeout-ms=N] [--concurrency=N] [--max-mutants=N]
           Writes DIR/stryker.config.json (mutate ranges from the changed hunks/functions) and
           DIR/mutation-plan.json (seed, env, in-sandbox argv, config hash).
           --max-mutants=N bounds the planned mutants per run (default 100, hard maximum 500); the sandbox
           enforces it with the trusted atd-budget reporter, which aborts before any mutant is tested.
  report   --stryker=FILE --risk=FILE [--plan=FILE] [--repo=PATH --candidate=SHA] [--equivalent=ID,ID] [--out=FILE]
           Normalize a Stryker JSON report (atd.mutation-report/v1). Survivors are test-suite gaps,
           never confirmed bugs. With --repo/--candidate the embedded sources are verified against
           the candidate revision; exit 1 if they differ.
  compare  --before=FILE --after=FILE [--out=FILE]
           List mutants that survived the first run and are killed by the second.
Exit: 0 ok, 1 failure, 2 usage.
`;

export async function main(argv) {
  const { flags, positional } = parseFlags(argv, { boolean: ['typescript-checker'] });
  const command = positional[0];
  if (flags.help || !command) { process.stdout.write(HELP); return flags.help ? 0 : 2; }
  const emit = (value) => {
    if (flags.out) writeJsonFile(flags.out, value);
    else process.stdout.write(`${JSON.stringify(value, null, 2)}\n`);
  };
  const num = (v, name) => {
    if (v === undefined) return undefined;
    if (!/^\d+$/.test(v)) throw new DiscoveryError('usage', `--${name} must be a non-negative integer`);
    return Number(v);
  };
  switch (command) {
    case 'config': {
      requireFlags(flags, ['risk', 'framework', 'out-dir']);
      const plan = createMutationPlan({
        riskReport: readJsonFile(flags.risk),
        framework: flags.framework,
        tests: flags.tests ? flags.tests.split(',').filter(Boolean) : [],
        seed: num(flags.seed, 'seed'),
        scope: flags.scope || 'hunks',
        vitestConfigFile: flags['vitest-config'],
        typescriptChecker: flags['typescript-checker'] === true,
        tsconfigFile: flags.tsconfig,
        excludedMutations: flags['exclude-mutations'] ? flags['exclude-mutations'].split(',').filter(Boolean) : [],
        timeoutMS: num(flags['timeout-ms'], 'timeout-ms'),
        concurrency: num(flags.concurrency, 'concurrency'),
        maxMutants: num(flags['max-mutants'], 'max-mutants'),
      });
      const written = writePlanFiles(plan, flags['out-dir']);
      process.stdout.write(`${JSON.stringify({ config: written.configPath, plan: written.planPath, configSha256: plan.configSha256, seed: plan.seed, maxMutants: plan.maxMutants, mutate: plan.strykerConfig.mutate }, null, 2)}\n`);
      return 0;
    }
    case 'report': {
      requireFlags(flags, ['stryker', 'risk']);
      const report = normalizeStrykerReport(readJsonFile(flags.stryker, { maxBytes: 256 * 1024 * 1024 }), {
        riskReport: readJsonFile(flags.risk),
        plan: flags.plan ? readJsonFile(flags.plan) : null,
        repository: flags.repo,
        candidateCommit: flags.candidate,
        equivalent: flags.equivalent ? flags.equivalent.split(',').filter(Boolean) : [],
      });
      emit(report);
      return report.sourcePreserved === false ? 1 : 0;
    }
    case 'compare': {
      requireFlags(flags, ['before', 'after']);
      emit(compareMutationRuns(readJsonFile(flags.before), readJsonFile(flags.after)));
      return 0;
    }
    default:
      throw new DiscoveryError('usage', `unknown command ${command}`);
  }
}

if (isMain(import.meta.url)) await runCli(main);
