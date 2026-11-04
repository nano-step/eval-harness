// run-mutation.mjs — `run.mjs mutation-evidence`: scoped StrykerJS runs, executed ONLY inside the atd-sandbox
// confinement (sandbox.mjs mutation), producing real surviving -> killed evidence.
//
//   baseline run : mutation-evidence --repo --commit --risk --dependencies --out=<dir>
//   with tests   : mutation-evidence --repo --commit --risk --dependencies --out=<dir> --round=<round dir>
//                  [--baseline=<baseline evidence dir>]   (adds a survivor -> killed comparison)
//
// The revision under test is exported inside the container; the host never runs Stryker and never mutates the
// repository. Accepted generated tests are overlaid read-only into the confined copy (only tests whose
// harness case status was PASS: a test that fails on the unmutated revision cannot kill a mutant by itself).
// Scope is the CHANGED FUNCTIONS (createMutationPlan scope "symbols": symbol ranges of each changed function, falling back to the
// changed hunks only when no symbol range exists), identical for the baseline and the with-generated-tests run (same
// config sha256 is enforced before any comparison); the mutant count is bounded by plan.maxMutants.
// All counts are computed from the raw Stryker report; absent evidence stays null, never zero.

import { execFile } from "node:child_process";
import { createHash } from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { stateDirFrom, verifyOutDir } from "./attest.mjs";
import { recomputeCase } from "./workflow-verify.mjs";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const SANDBOX_CLI = path.join(HERE, "sandbox.mjs");
const sha256 = data => createHash("sha256").update(data).digest("hex");
const CAPTURED_STATUS = { Killed: "killed", Survived: "survived", NoCoverage: "survived" };

class UsageError extends Error {}
/** A mutation seal that is missing, invalid, or does not bind what is being measured: fail fast (exit 13), never "measured". */
export class SealError extends Error {}

function git(repo, args) {
  return new Promise((resolve, reject) => {
    execFile("git", ["-C", repo, ...args], { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 }, (err, stdout) => (err ? reject(err) : resolve(stdout)));
  });
}

/** Counts and per-mutant keys straight from the raw Stryker mutation-testing-elements report. */
export function summarizeRawReport(raw) {
  const mutants = [];
  const counts = { total: 0, killed: 0, survived: 0, noCoverage: 0, timeout: 0, compileError: 0, runtimeError: 0, ignored: 0, pending: 0 };
  for (const [file, entry] of Object.entries(raw?.files ?? {})) {
    for (const m of entry.mutants ?? []) {
      const key = [file, m.mutatorName, m.location?.start?.line, m.location?.start?.column, m.location?.end?.line, m.location?.end?.column, m.replacement ?? ""].join("|");
      mutants.push({ key, id: String(m.id), file, mutator: m.mutatorName ?? null, line: m.location?.start?.line ?? null, replacement: m.replacement ?? null, status: m.status ?? null });
      counts.total += 1;
      const bucket = { Killed: "killed", Survived: "survived", NoCoverage: "noCoverage", Timeout: "timeout", CompileError: "compileError", RuntimeError: "runtimeError", Ignored: "ignored" }[m.status] ?? "pending";
      counts[bucket] += 1;
    }
  }
  const detected = counts.killed + counts.timeout;
  const valid = detected + counts.survived + counts.noCoverage;
  return { counts, mutants, score: valid === 0 ? null : Math.round((detected / valid) * 10000) / 100, scoreFormula: "(killed + timeout) / (killed + timeout + survived + noCoverage) * 100; compile errors, runtime errors and ignored mutants excluded" };
}

export function compareRaw(before, after) {
  const byKey = new Map(after.mutants.map(m => [m.key, m]));
  const transitions = [];
  for (const m of before.mutants) {
    const next = byKey.get(m.key);
    const was = CAPTURED_STATUS[m.status] ?? null;
    const now = next ? (CAPTURED_STATUS[next.status] ?? null) : null;
    if (was === "survived" && now === "killed") transitions.push({ key: m.key, file: m.file, line: m.line, mutator: m.mutator, replacement: m.replacement, before: m.status, after: next.status });
  }
  const survivedBefore = before.mutants.filter(m => CAPTURED_STATUS[m.status] === "survived").length;
  return { survivedBefore, killedAfterSurvivalBefore: transitions.length, transitions, unmatchedBeforeMutants: before.mutants.filter(m => !byKey.has(m.key)).length };
}

const SAFE_SEGMENT = /^[A-Za-z0-9._@+-]+$/;
const MAX_TEST_BYTES = 32 * 1024;
const MAX_MANIFEST_BYTES = 64 * 1024;

/** lstat every component from `root` down; no component may be a symlink. Returns the final lstat or a reason. */
function lstatNoLinks(root, segments) {
  let cursor = root;
  let st;
  try {
    st = fs.lstatSync(cursor);
  } catch {
    return { problem: `${path.basename(cursor)} is missing` };
  }
  if (st.isSymbolicLink() || !st.isDirectory()) return { problem: `${path.basename(cursor)} is not a plain directory` };
  for (const [i, seg] of segments.entries()) {
    cursor = path.join(cursor, seg);
    try {
      st = fs.lstatSync(cursor);
    } catch {
      return { problem: "test file is missing" };
    }
    if (st.isSymbolicLink()) return { problem: "a path component is a symbolic link" };
    if (i < segments.length - 1 && !st.isDirectory()) return { problem: "a path ancestor is not a directory" };
  }
  return { st, file: cursor };
}

const MAX_REVIEW_BYTES = 16 * 1024;

/** null when there is no review or it is a well-formed bound PASS; otherwise the reason the test must not be overlaid. */
function reviewVetoReason(workdir, { id, testSha256, manifestSha256, attested }) {
  const located = lstatNoLinks(workdir, ["expectation-review.json"]);
  if (located.problem === "test file is missing") return null;
  if (located.problem || !located.st.isFile() || located.st.size > MAX_REVIEW_BYTES) return `supplied expectation review is not a plain bounded file (${located.problem ?? "size or type"})`;
  let review;
  try { review = JSON.parse(fs.readFileSync(located.file, "utf8")); } catch { return "supplied expectation review is not valid JSON"; }
  const bound = review?.candidateId === id && review.testSha256 === testSha256 && review.candidateManifestSha256 === manifestSha256
    && review.testSha256 === attested.testSha256 && review.candidateManifestSha256 === attested.candidateManifestSha256
    && review.specSha256 === (attested.specSha256 ?? null) && review.specSha256 !== null;
  if (!bound) return "supplied expectation review is not bound to the attested candidate/test/spec/manifest hashes";
  if (review.verdict === "FAIL") return "operator expectation review verdict is FAIL: the test asserts behaviour the specification does not promise";
  if (review.verdict !== "PASS") return "supplied expectation review has no PASS|FAIL verdict";
  return null;
}

/**
 * Selects the generated tests that may be overlaid for a with-generated-tests mutation run.
 *
 * A candidate's testFile is a path relative to the REVISION root (the request convention is e.g. `test/<id>.test.ts`,
 * stored as candidates/<id>/tests/test/<id>.test.ts) because generated imports such as `../src/collision` are relative
 * to that location. Every safe revision-relative path is accepted, including flat root files and several top-level
 * directories, and is overlaid at exactly that path (sandbox `--tests-rel=.`); nothing is moved under `tests/`.
 *
 * Authenticity does not rest on the raw round summary. A candidate is used only when
 *   - its provenance is bound to this round's base and the mutation commit,
 *   - the candidate directory, tests root, every ancestor and the files are plain (no symlinks), the test is <= 32 KiB,
 *   - the manifest bytes equal the signed candidateManifestSha256 and the test bytes equal candidate.testSha256 and the
 *     signed testSha256 of the preserved attestation,
 *   - the existing constrained workflow-verify replay of its preserved case (bindings, allowlist, signature, digests via
 *     grade.sh) is PASS (a test that fails on the unmutated revision never runs),
 *   - the path does not already exist in the revision and no other candidate provides it.
 * Anything else is skipped WITH a reason, never silently.
 */
export function collectAcceptedTests({ round, commit, tracked = [], stateDir, verifyCase = recomputeCase, env = process.env }) {
  const summary = JSON.parse(fs.readFileSync(path.join(round, "round-summary.json"), "utf8"));
  const skipped = [];
  const skip = (candidateId, reason) => skipped.push({ candidateId, reason });
  if (summary.candidateCommit !== commit) throw new UsageError(`the round was evaluated at ${summary.candidateCommit}, not at the mutation commit ${commit}`);
  const trackedSet = new Set(tracked);
  const childEnv = { ...env };
  if (stateDir) childEnv.EVAL_STATE_DIR = stateDir;
  const files = [];
  const seen = new Set();
  for (const id of summary.candidates?.acceptedIds ?? []) {
    if (!/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(id)) { skip(String(id), "candidate id is not a safe path segment"); continue; }
    const candidateDir = path.join(round, "candidates", id);
    const manifestLink = lstatNoLinks(candidateDir, ["candidate.json"]);
    if (manifestLink.problem || !manifestLink.st.isFile() || manifestLink.st.size > MAX_MANIFEST_BYTES) { skip(id, manifestLink.problem ?? "candidate.json is not a plain file within the size bound"); continue; }
    const manifestBytes = fs.readFileSync(manifestLink.file);
    let candidate;
    try { candidate = JSON.parse(manifestBytes.toString("utf8")); } catch { skip(id, "candidate.json is not valid JSON"); continue; }
    if (candidate.id !== id) { skip(id, "candidate id does not match its directory"); continue; }
    if (candidate.provenance?.candidateCommit !== commit || candidate.provenance?.baseCommit !== summary.baseCommit) { skip(id, "candidate provenance is not bound to this round's base and the mutation commit"); continue; }
    const rel = candidate.testFile;
    const segments = typeof rel === "string" ? rel.split("/") : [];
    if (segments.length === 0 || !segments.every(seg => SAFE_SEGMENT.test(seg) && seg !== "." && seg !== ".." && seg !== ".git" && seg !== "node_modules")) { skip(id, "testFile must be a safe relative path"); continue; }
    const located = lstatNoLinks(path.join(candidateDir, "tests"), segments);
    if (located.problem || !located.st.isFile()) { skip(id, located.problem ?? "test file is not a regular file"); continue; }
    if (located.st.size > MAX_TEST_BYTES) { skip(id, `test file exceeds ${MAX_TEST_BYTES} bytes`); continue; }
    const bytes = fs.readFileSync(located.file);
    const testSha256 = sha256(bytes);
    if (testSha256 !== candidate.testSha256) { skip(id, "test bytes do not match candidate.testSha256"); continue; }
    if (trackedSet.has(rel)) { skip(id, `${rel} already exists in the revision (overlay would collide)`); continue; }
    if (seen.has(rel)) { skip(id, `another accepted candidate already provides ${rel}`); continue; }
    const verdict = verifyCase({ caseDir: path.join(round, "evidence", id), env: childEnv });
    if (!verdict.recomputed) { skip(id, `preserved case could not be independently verified: ${verdict.reason}`); continue; }
    if (verdict.status !== "PASS") { skip(id, `independent replay status is ${verdict.status}, not PASS: a test that fails on the unmutated revision is never run`); continue; }
    let attested = {};
    try { attested = JSON.parse(fs.readFileSync(path.join(round, "evidence", id, "workdir", "atd-out", "attestation.json"), "utf8")); } catch { attested = {}; }
    if (attested.testSha256 !== testSha256) { skip(id, "the signed attestation's testSha256 does not match the bytes to overlay"); continue; }
    if (attested.candidateManifestSha256 !== sha256(manifestBytes)) { skip(id, "the signed attestation's candidateManifestSha256 does not match candidate.json (metadata swapped)"); continue; }
    // A supplied operator expectation review can only VETO (never elevate): a FAIL verdict, or a review that is malformed or
    // not bound to the attested candidate/test/spec/manifest hashes, keeps the test out. A missing review stays advisory.
    const reviewVeto = reviewVetoReason(path.join(round, "evidence", id, "workdir"), { id, testSha256, manifestSha256: sha256(manifestBytes), attested });
    if (reviewVeto) { skip(id, reviewVeto); continue; }
    seen.add(rel);
    files.push({ candidateId: id, testFile: rel, testSha256, killsMutantIds: candidate.killsMutantIds ?? null, relInRoot: rel, bytes });
  }
  return { files, skipped, testsRel: "." };
}

// --- signed-evidence authority ------------------------------------------------------------------------------------------------
// evidence.json / normalized.json in a baseline directory are plain, unsigned sidecars: anyone with file access can edit them.
// Comparison authority comes ONLY from the sandbox's signed attestation (verified with the existing attest.mjs verifier against
// the caller's trusted state / external allowed signers) and the signed raw stryker_report it covers.

const canon = v => (Array.isArray(v) ? v.map(canon) : v && typeof v === "object" ? Object.fromEntries(Object.keys(v).sort().map(k => [k, canon(v[k])])) : v);
const canonicalText = v => JSON.stringify(canon(v));

/** Replicates the sandbox's tests-tree hash: sorted depth-first walk, sha256 over `rel\0sha256(bytes)\0` records. */
export function treeSha256(dir) {
  const records = [];
  const walk = (abs, rel) => {
    for (const name of fs.readdirSync(abs).sort()) {
      const full = path.join(abs, name);
      const r = rel ? `${rel}/${name}` : name;
      const st = fs.lstatSync(full);
      if (st.isSymbolicLink() || (!st.isFile() && !st.isDirectory())) throw new SealError(`unsafe entry in tests tree: ${r}`);
      if (st.isDirectory()) walk(full, r);
      else records.push(`${r}\0${sha256(fs.readFileSync(full))}\0`);
    }
  };
  walk(dir, "");
  return sha256(records.join(""));
}

/**
 * Verifies a sandbox mutation seal and returns the verified attestation, execution record and trust.
 * `expect` = { commit, configSha256 (sha256 of the RAW stryker config bytes), testsTreeSha256, maxMutants? }.
 * Never throws: `{ ok:false, status, reason }` means the directory cannot be used as evidence.
 */
export function verifyMutationSeal(sandboxDir, { stateDir, env = process.env, expect }) {
  let v;
  try {
    v = verifyOutDir(sandboxDir, { stateDir, env });
  } catch (error) {
    return { ok: false, status: "invalid", reason: `seal verification failed: ${error.message}` };
  }
  if (v.status !== "valid") return { ok: false, status: v.status, reason: `seal ${v.status}: ${v.reason}` };
  const bad = reason => ({ ok: false, status: "invalid", reason });
  let attBytes;
  let att;
  try {
    attBytes = fs.readFileSync(path.join(sandboxDir, "attestation.json"));
    if (sha256(attBytes) !== v.attestationSha256) return bad("attestation changed after verification");
    att = JSON.parse(attBytes.toString("utf8"));
  } catch {
    return bad("attestation is unreadable");
  }
  if (att.kind !== "mutation") return bad(`attestation kind '${att.kind}' is not 'mutation'`);
  if (!Array.isArray(att.executions) || att.executions.length !== 1 || att.executions[0].side !== "mutant") return bad("a mutation seal must attest exactly one mutant execution");
  let rec;
  try {
    const bytes = fs.readFileSync(path.join(sandboxDir, att.executions[0].recordFile));
    if (sha256(bytes) !== att.executions[0].recordSha256) return bad("execution record changed after verification");
    rec = JSON.parse(bytes.toString("utf8"));
  } catch {
    return bad("execution record is unreadable");
  }
  if (rec.side !== "mutant" || rec.framework !== "stryker") return bad("execution record is not a stryker mutant execution");
  if (rec.revision?.commit !== expect.commit) return bad(`sealed revision ${rec.revision?.commit} is not the mutation commit ${expect.commit}`);
  if (att.candidateManifestSha256 !== expect.configSha256) return bad("the sealed config digest differs from this run's Stryker configuration (config binding)");
  if (att.testSha256 !== expect.testsTreeSha256 || rec.testsTreeSha256 !== expect.testsTreeSha256) return bad("the sealed tests tree differs from the tests this run selected");
  if (typeof expect.maxMutants === "number" && rec.mutationBudget?.maxMutants !== expect.maxMutants) return bad("the sealed mutant budget differs from this run's budget");
  return { ok: true, status: "valid", trust: v.trust, attestationSha256: v.attestationSha256, attestation: att, record: rec };
}

/** Reads the signed raw report / budget artifacts named by the VERIFIED execution record (digests were verified with the seal). */
export function readSealedArtifacts(sandboxDir, record) {
  const real = fs.realpathSync(sandboxDir);
  const read = role => {
    const art = (record.artifacts ?? []).find(a => a.role === role);
    if (!art) return null;
    const file = fs.realpathSync(path.join(sandboxDir, art.path));
    if (!file.startsWith(real + path.sep)) throw new SealError(`${role} artifact escapes the sealed directory`);
    const bytes = fs.readFileSync(file);
    if (sha256(bytes) !== art.sha256) throw new SealError(`${role} artifact digest differs from the sealed record`);
    return { path: file, sha256: art.sha256, bytes, json: JSON.parse(bytes.toString("utf8")) };
  };
  return { report: read("stryker_report"), budget: read("mutation_budget") };
}

/** Fields that must be identical for a before/after comparison. Mount/source/temp paths and the tests tree are intentionally excluded. */
export function environmentDiffs(a, b) {
  const pick = r => ({
    "image.ref": r.image?.ref, "image.digest": r.image?.digest, "image.id": r.image?.id, nodeVersion: r.nodeVersion,
    depsSnapshotSha256: r.depsSnapshotSha256, lockfileSha256: r.lockfileSha256, seed: r.seed, env: r.env === undefined ? undefined : canonicalText(r.env),
    "profile.id": r.profile?.id, "profile.policySha256": r.profile?.policySha256,
    "revision.commit": r.revision?.commit, "revision.treeSha256": r.revision?.treeSha256, "revision.lockfileSha256": r.revision?.lockfileSha256,
    argv: r.argv === undefined ? undefined : canonicalText(r.argv), framework: r.framework, "mutationBudget.maxMutants": r.mutationBudget?.maxMutants,
  });
  const x = pick(a);
  const y = pick(b);
  return Object.keys(x).filter(k => x[k] === undefined || y[k] === undefined || x[k] !== y[k]).map(k => ({ field: k, baseline: x[k] === undefined ? "(missing)" : x[k], current: y[k] === undefined ? "(missing)" : y[k] }));
}

/**
 * Loads the baseline ONLY from its signed sandbox seal (<baselineDir>/sandbox) and recomputes its summary and normalized
 * report from the signed raw report with this run's plan, risk report and repository commit. The baseline's plain
 * evidence.json / normalized.json are never read. Throws SealError (fail fast) when anything is missing or invalid.
 */
export function loadSealedBaseline({ baselineDir, expect, riskReport, plan, repo, commit, stateDir, env, normalizeStrykerReport }) {
  const sandboxDir = path.join(path.resolve(baselineDir), "sandbox");
  const seal = verifyMutationSeal(sandboxDir, { stateDir, env, expect: { ...expect, testsTreeSha256: sha256("") } });
  if (!seal.ok) throw new SealError(`baseline cannot be used: ${seal.reason}`);
  if (seal.record.outcome !== "pass" || seal.record.exitCode !== 0 || seal.record.timedOut) throw new SealError(`baseline execution did not pass (outcome ${seal.record.outcome}, ${seal.record.errorClass ?? "no error class"})`);
  if (seal.record.mutationBudget?.allowed !== true) throw new SealError("baseline mutant budget was not allowed");
  let arts;
  try { arts = readSealedArtifacts(sandboxDir, seal.record); } catch (error) { throw new SealError(`baseline artifacts: ${error.message}`); }
  if (!arts.report) throw new SealError("baseline seal has no stryker_report artifact");
  const summary = summarizeRawReport(arts.report.json);
  const normalized = normalizeStrykerReport(arts.report.json, { riskReport, plan, repository: repo, candidateCommit: commit });
  if (normalized.sourcePreserved === false) throw new SealError("baseline report embeds sources that differ from the mutation commit (source preservation false)");
  return { seal, summary, normalized, reportSha256: arts.report.sha256 };
}

function runSandbox(args, env, timeoutMs) {
  return new Promise(resolve => {
    execFile(process.execPath, [SANDBOX_CLI, ...args], { encoding: "utf8", env, timeout: timeoutMs, maxBuffer: 8 * 1024 * 1024 }, (err, stdout, stderr) => {
      resolve({ exitCode: err ? (typeof err.code === "number" ? err.code : null) : 0, timedOut: Boolean(err?.killed), stdout, stderr });
    });
  });
}

export async function runMutationEvidence(opts) {
  for (const name of ["repo", "commit", "risk", "dependencies", "out"]) if (opts[name] === undefined) throw new UsageError(`missing required --${name}=...`);
  const { createMutationPlan, normalizeStrykerReport, compareMutationRuns } = await import("./mutation.mjs");
  const repo = fs.realpathSync(opts.repo);
  const outDir = opts.out;
  if (fs.existsSync(outDir)) throw new UsageError(`--out already exists (evidence is never overwritten): ${outDir}`);
  const framework = opts.framework ?? "vitest";
  const seed = opts.seed ?? 1337;
  const riskReport = JSON.parse(fs.readFileSync(opts.risk, "utf8"));
  const commit = (await git(repo, ["rev-parse", "--verify", `${opts.commit}^{commit}`])).trim();
  if (riskReport.candidateCommit !== commit) throw new UsageError("--commit must equal the risk report's candidateCommit (mutants are scoped to its changed ranges)");
  const tracked = (await git(repo, ["ls-tree", "-r", "--name-only", commit])).split("\n").filter(Boolean);
  const existingTests = tracked.filter(f => /(^|\/)(tests?|__tests__)\//.test(f) || /\.(test|spec)\.[cm]?[jt]sx?$/.test(f));

  const plan = createMutationPlan({ riskReport, framework, tests: existingTests, seed, scope: "symbols", ...(opts["max-mutants"] !== undefined ? { maxMutants: opts["max-mutants"] } : {}) });
  const configText = `${JSON.stringify(plan.strykerConfig, null, 2)}\n`;
  const configSha256 = sha256(configText); // the sandbox seals the sha256 of the RAW config bytes (candidateManifestSha256)
  const env = { ...process.env };
  if (opts["state-dir"]) env.EVAL_STATE_DIR = opts["state-dir"];
  const trustedStateDir = stateDirFrom(env);

  // A baseline is trusted ONLY through its signed sandbox seal, verified BEFORE any Docker execution or output creation.
  let baseline = null;
  if (opts.baseline) {
    baseline = loadSealedBaseline({
      baselineDir: opts.baseline, expect: { commit, configSha256, maxMutants: plan.maxMutants }, riskReport, plan, repo, commit,
      stateDir: trustedStateDir, env, normalizeStrykerReport,
    });
  }

  fs.mkdirSync(outDir, { recursive: true });
  fs.writeFileSync(path.join(outDir, "plan.json"), `${JSON.stringify(plan, null, 2)}\n`);
  const configPath = path.join(outDir, "stryker.config.json");
  fs.writeFileSync(configPath, configText);

  const label = opts.round ? "with-generated-tests" : "baseline";
  let accepted = [];
  let skippedTests = [];
  let testsDir = null;
  let testsRel = null;
  let testsTreeSha256 = sha256("");
  if (opts.round) {
    const picked = collectAcceptedTests({ round: path.resolve(opts.round), commit, tracked, stateDir: opts["state-dir"] });
    if (picked.files.length === 0) {
      throw new UsageError(`no accepted generated test can be overlaid (${picked.skipped.map(x => `${x.candidateId}: ${x.reason}`).join("; ") || "none were accepted"})`);
    }
    testsDir = path.join(outDir, "accepted-tests");
    fs.mkdirSync(testsDir);
    for (const f of picked.files) {
      const dest = path.join(testsDir, ...f.relInRoot.split("/"));
      fs.mkdirSync(path.dirname(dest), { recursive: true });
      fs.writeFileSync(dest, f.bytes, { flag: "wx" });
    }
    testsRel = picked.testsRel;
    testsTreeSha256 = treeSha256(testsDir);
    accepted = picked.files.map(({ bytes, relInRoot, ...rest }) => rest);
    skippedTests = picked.skipped;
  }

  const sandboxOut = path.join(outDir, "sandbox");
  const args = ["mutation", `--repository=${repo}`, `--commit=${commit}`, `--dependencies=${opts.dependencies}`, `--config=${configPath}`, `--out=${sandboxOut}`, `--seed=${seed}`, `--candidate-id=mutation-${label}`];
  if (typeof plan.maxMutants === "number") args.push(`--max-mutants=${plan.maxMutants}`);
  if (testsDir) args.push(`--tests-dir=${testsDir}`, `--tests-rel=${testsRel}`);
  if (opts["timeout-seconds"]) args.push(`--timeout=${opts["timeout-seconds"]}`);
  const exec = await runSandbox(args, env, ((opts["timeout-seconds"] ?? 1800) + 120) * 1000);

  const evidence = {
    schema: "atd.mutation-evidence/v1", label, repository: repo, commit, riskSha256: sha256(fs.readFileSync(opts.risk)),
    configSha256, seed, acceptedTests: accepted, skippedTests, testsRel, testsTreeSha256,
    sandbox: { exitCode: exec.exitCode, timedOut: exec.timedOut, stdout: exec.stdout.slice(-2000), stderr: exec.stderr.slice(-2000), outDir: sandboxOut },
    authority: "signed sandbox seal (attest.mjs verification) and the signed raw stryker_report; this file is a derived, unsigned summary",
    seal: null, outcome: null, errorClass: null, executionRecord: null, reportPath: null, reportSha256: null, counts: null, score: null, scoreFormula: null, normalizedPath: null, gaps: null, comparison: null,
    baseline: baseline ? { dir: path.resolve(opts.baseline), trust: baseline.seal.trust, attestationSha256: baseline.seal.attestationSha256, executionId: baseline.seal.record.executionId, reportSha256: baseline.reportSha256, counts: baseline.summary.counts, score: baseline.summary.score } : null,
  };
  let refusal = null;

  // Nothing under <out>/sandbox is believed (budget, report counts, record) before its seal verifies.
  const seal = verifyMutationSeal(sandboxOut, { stateDir: trustedStateDir, env, expect: { commit, configSha256, testsTreeSha256, maxMutants: plan.maxMutants } });
  evidence.seal = seal.ok ? { status: "valid", trust: seal.trust, attestationSha256: seal.attestationSha256 } : { status: seal.status, reason: seal.reason };
  if (seal.ok) {
    const record = seal.record;
    evidence.executionRecord = { path: path.join(sandboxOut, "mutant.json"), sha256: seal.attestation.executions[0].recordSha256, executionId: record.executionId, outcome: record.outcome, errorClass: record.errorClass ?? null, image: record.image ?? null, durationMs: record.durationMs ?? null };
    evidence.outcome = record.outcome;
    evidence.errorClass = record.errorClass ?? null;
    let arts = { report: null, budget: null };
    try { arts = readSealedArtifacts(sandboxOut, record); } catch (error) { refusal = { reason: "sealed_artifact_unreadable", detail: error.message }; }
    // The sandbox's budget guard aborts BEFORE any mutant test runs when the plan exceeds the cap. Report that as an
    // explicit refusal (never as 0 mutants or a score) together with the signed budget artifact it produced.
    if (arts.budget || record.errorClass === "budget_exceeded") {
      evidence.budget = {
        maxMutants: opts["max-mutants"] ?? plan.maxMutants ?? null, refused: record.errorClass === "budget_exceeded",
        artifact: arts.budget ? { path: arts.budget.path, sha256: arts.budget.sha256 } : null, detail: arts.budget?.json ?? null,
        note: record.errorClass === "budget_exceeded" ? "mutation run refused: the planned mutant count exceeded the cap; no mutant was executed and no score exists" : null,
      };
    }
    if (arts.report && record.outcome === "pass" && !refusal) {
      const raw = arts.report.json;
      const normalized = normalizeStrykerReport(raw, { riskReport, plan, repository: repo, candidateCommit: commit });
      if (normalized.sourcePreserved === false) {
        refusal = { reason: "source_not_preserved", detail: "the sealed report embeds sources that differ from the mutation commit; nothing is published as measured" };
      } else {
        const summary = summarizeRawReport(raw);
        evidence.reportPath = arts.report.path;
        evidence.reportSha256 = arts.report.sha256;
        evidence.counts = summary.counts;
        evidence.score = summary.score;
        evidence.scoreFormula = summary.scoreFormula;
        evidence.mutants = summary.mutants;
        evidence.normalizedPath = path.join(outDir, "normalized.json");
        fs.writeFileSync(evidence.normalizedPath, `${JSON.stringify(normalized, null, 2)}\n`);
        evidence.gaps = (normalized.gaps ?? []).length;
        if (baseline) {
          const diffs = environmentDiffs(baseline.seal.record, record);
          if (!baseline.seal.attestation.runner?.scriptSha256 || baseline.seal.attestation.runner.scriptSha256 !== seal.attestation.runner?.scriptSha256) {
            diffs.push({ field: "runner.scriptSha256", baseline: baseline.seal.attestation.runner?.scriptSha256 ?? "(missing)", current: seal.attestation.runner?.scriptSha256 ?? "(missing)" });
          }
          if (diffs.length > 0) {
            refusal = { reason: "environment_mismatch", detail: "the baseline and this run were not executed in the same sealed environment; no comparison and no score gain is published", diffs };
          } else {
            const official = compareMutationRuns(baseline.normalized, normalized);
            evidence.comparison = {
              baselineDir: path.resolve(opts.baseline), baselineScore: baseline.summary.score, baselineSeal: { trust: baseline.seal.trust, attestationSha256: baseline.seal.attestationSha256, executionId: baseline.seal.record.executionId },
              currentSeal: { trust: seal.trust, attestationSha256: seal.attestationSha256 }, authority: "recomputed from the signed raw stryker_report of both runs (sidecar evidence.json/normalized.json were not read)",
              ...compareRaw({ mutants: baseline.summary.mutants }, summary),
              normalizedComparison: { scoreDelta: official.scoreDelta, killedNow: official.killedNow, stillSurviving: official.stillSurviving.length, newlySurvived: official.newlySurvived.length, onlyBefore: official.onlyBefore.length, onlyAfter: official.onlyAfter.length },
            };
          }
        }
      }
    }
  }
  if (refusal) evidence.refusal = refusal;
  evidence.status = refusal || evidence.budget?.refused ? "refused" : evidence.counts ? "measured" : "unavailable";
  fs.writeFileSync(path.join(outDir, "evidence.json"), `${JSON.stringify(evidence, null, 2)}\n`);
  process.stdout.write(`ATD_MUTATION_EVIDENCE=${path.join(outDir, "evidence.json")}\nATD_MUTATION_STATUS=${evidence.status}\n`);
  return evidence.status === "measured" ? 0 : 13;
}
