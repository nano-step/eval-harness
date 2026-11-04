#!/usr/bin/env node
// run.mjs — Autonomous Test Discovery pipeline (workflow owner).
//
//   request  : deterministic change-risk report + bounded generation request (risk.mjs, candidates.mjs)
//   generate : ONE bounded call through the existing OMP runtime (configured `implement` role). Output is
//              untrusted data; nothing generated is ever executed on the host.
//   validate : candidates.mjs materializes candidates through a strict whitelist (manifest + test file only)
//   cases    : temporary skill YAML cases (runner atd-sandbox, check discovery_finding) are written
//   evaluate : the EXISTING scripts/eval/run.sh runs them (primary + 2 fresh stability samples, JUnit/SARIF)
//   consume  : results.json is read back; every non-PASS status and every finding is preserved
//
// The generator has no grading authority. Operator expectation reviews (--approval-dir) are copied verbatim
// from a trusted path and are never taken from model output. Each invocation writes a NEW round-NNN
// directory; earlier rounds are never overwritten.
//
// Exit codes: 0 pipeline completed and results consumed (findings/non-PASS are in the summary, not the
// exit code), 2 usage, 13 harness/sandbox error, 20 no executable candidates, 21 generation failure.
// The authoritative result is always the round-summary.json whose path is printed as ATD_SUMMARY=<path>.

import { spawn, spawnSync, execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { analyzeChange } from "./risk.mjs";
import { createGenerationRequest, materializeCandidates, validateCandidateSet } from "./candidates.mjs";
import { discoverRoleSelector, generateWithOmp, ompVersion, parseSelector, sha256Hex } from "./workflow-omp.mjs";
import { recomputeRound } from "./workflow-verify.mjs";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const DEFAULT_RUN_SH = path.resolve(HERE, "..", "run.sh");
const POLICY_FILE = path.join(HERE, "policy", "atd-sandbox.v1.json");
const SANDBOX_CLI = path.join(HERE, "sandbox.mjs");

export const EXIT = { ok: 0, usage: 2, harness: 13, noCandidates: 20, generation: 21 };
const SAFE_ID = /^[A-Za-z0-9][A-Za-z0-9._-]*$/;
const SAFE_REF = /^[A-Za-z0-9_][A-Za-z0-9._/@~^{}+-]*$/;
const MAX_APPROVAL_BYTES = 16 * 1024;

class UsageError extends Error {}
class PipelineError extends Error {
  constructor(stage, code, message) {
    super(message);
    this.stage = stage;
    this.code = code;
  }
}

const sha256File = file => sha256Hex(fs.readFileSync(file));
const nowIso = () => new Date().toISOString();
const truncate = (value, max = 600) => (typeof value === "string" && value.length > max ? `${value.slice(0, max)}...` : value);

// --- options ---------------------------------------------------------------------------------------------

const OPTION_TYPES = {
  repo: "path", base: "ref", candidate: "ref", commit: "ref", spec: "path", out: "path", dependencies: "path",
  "eval-harness": "path", "state-dir": "path", framework: "string", skill: "id", "max-model-calls": "int",
  "max-candidates": "int", model: "string", "require-model": "string", "generation-timeout": "int",
  transport: "string", "fixture-response": "path", "omp-bin": "string", seed: "int", "timeout-seconds": "int",
  image: "string", "stability-samples": "int", "approval-dir": "path", reevaluate: "path", "harness-timeout": "int",
  "max-mutants": "int", "mutation-report": "path", "mutation-baseline": "path", "mutation-with": "path", round: "path", risk: "path", baseline: "path", name: "string", json: "bool",
};

export function parseOptions(argv) {
  const opts = {};
  const positional = [];
  for (const arg of argv) {
    if (!arg.startsWith("--")) {
      positional.push(arg);
      continue;
    }
    const eq = arg.indexOf("=");
    const name = arg.slice(2, eq === -1 ? undefined : eq);
    const type = OPTION_TYPES[name];
    if (!type) throw new UsageError(`unknown option --${name}`);
    if (type === "bool") {
      if (eq !== -1) throw new UsageError(`--${name} takes no value`);
      opts[name] = true;
      continue;
    }
    const value = eq === -1 ? "" : arg.slice(eq + 1);
    if (value === "" || value.includes("\0")) throw new UsageError(`--${name} requires a value`);
    if (type === "int") {
      if (!/^[0-9]{1,9}$/.test(value)) throw new UsageError(`--${name} must be a non-negative integer`);
      opts[name] = Number(value);
    } else if (type === "ref") {
      if (value.startsWith("-") || !SAFE_REF.test(value)) throw new UsageError(`--${name} must be a commit-ish`);
      opts[name] = value;
    } else if (type === "id") {
      if (!SAFE_ID.test(value)) throw new UsageError(`--${name} must match ${SAFE_ID}`);
      opts[name] = value;
    } else if (type === "path") {
      opts[name] = path.resolve(value);
    } else {
      opts[name] = value;
    }
  }
  return { opts, positional };
}

function need(opts, ...names) {
  for (const name of names) if (opts[name] === undefined) throw new UsageError(`missing required --${name}=...`);
}

function bounded(opts, name, fallback, min, max) {
  const value = opts[name] ?? fallback;
  if (value < min || value > max) throw new UsageError(`--${name} must be between ${min} and ${max}`);
  return value;
}

// --- small io helpers --------------------------------------------------------------------------------------

function writeJsonExclusive(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`, { flag: "wx" });
}

function writeTextExclusive(file, text, mode) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, text, { flag: "wx", ...(mode ? { mode } : {}) });
}

function git(repo, args) {
  return execFileSync("git", ["-C", repo, ...args], {
    encoding: "utf8", maxBuffer: 64 * 1024 * 1024, env: { ...process.env, GIT_TERMINAL_PROMPT: "0" }, stdio: ["ignore", "pipe", "pipe"],
  });
}

function resolveCommit(repo, ref, label) {
  try {
    const sha = git(repo, ["rev-parse", "--verify", `${ref}^{commit}`]).trim();
    if (!/^[0-9a-f]{40}$/.test(sha)) throw new Error("not a full sha");
    return sha;
  } catch {
    throw new UsageError(`${label} '${ref}' does not resolve to a commit in ${repo}`);
  }
}

function readJsonIfPresent(file) {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch {
    return null;
  }
}

function isInside(parent, child) {
  const rel = path.relative(parent, child);
  return rel === "" || (!rel.startsWith("..") && !path.isAbsolute(rel));
}

/** realpath of the nearest existing ancestor plus the not-yet-existing remainder. */
function realpathLoose(target) {
  let current = path.resolve(target);
  const rest = [];
  while (!fs.existsSync(current)) {
    rest.unshift(path.basename(current));
    const parent = path.dirname(current);
    if (parent === current) break;
    current = parent;
  }
  return path.join(fs.realpathSync(current), ...rest);
}

function shellQuote(value) {
  return `'${String(value).replace(/'/g, `'\\''`)}'`;
}

// --- validation of the environment before any model call ---------------------------------------------------

function checkDependencies(dependencies, framework) {
  if (!dependencies) {
    if (framework === "vitest") throw new UsageError("--dependencies=<snapshot dir> is required for vitest (build it with scripts/eval/discovery/setup-deps.sh)");
    return;
  }
  if (!fs.statSync(path.join(dependencies, "node_modules"), { throwIfNoEntry: false })?.isDirectory()
    || !fs.statSync(path.join(dependencies, "package-lock.json"), { throwIfNoEntry: false })?.isFile()) {
    throw new UsageError(`dependency snapshot ${dependencies} must contain node_modules/ and package-lock.json`);
  }
}

function readPolicyImage(imageOverride) {
  if (imageOverride) return imageOverride;
  try {
    const policy = JSON.parse(fs.readFileSync(POLICY_FILE, "utf8"));
    const candidate = policy.image ?? policy.defaultImage ?? (Array.isArray(policy.allowedImages) ? policy.allowedImages[0] : null);
    return typeof candidate === "string" ? candidate : candidate?.ref ?? null;
  } catch {
    return null;
  }
}

/** Fail before spending a model call when the confined runner cannot possibly execute. No host fallback. */
function preflightSandbox(imageOverride) {
  const server = spawnSync("docker", ["version", "--format", "{{.Server.Version}}"], { encoding: "utf8", timeout: 20000 });
  if (server.error || server.status !== 0) {
    throw new PipelineError("preflight", "sandbox_unavailable", "docker daemon is not reachable; the atd-sandbox runner fails closed and generated tests are never run on the host");
  }
  const image = readPolicyImage(imageOverride);
  if (image) {
    const inspect = spawnSync("docker", ["image", "inspect", "--format", "{{.Id}}", image], { encoding: "utf8", timeout: 20000 });
    if (inspect.status !== 0) {
      throw new PipelineError("preflight", "sandbox_image_missing", `pinned sandbox image ${image} is not present locally (images are never pulled by the runner)`);
    }
  }
  return image;
}

// --- case YAML ---------------------------------------------------------------------------------------------

const q = JSON.stringify;

export function renderCaseYaml({ skill, candidate, severity, runnerConfig, fixtures, description }) {
  const lines = [
    "schema_version: 2",
    `id: ${q(candidate.id)}`,
    "mode: deterministic",
    "eval_type: capability",
    "compare_to_baseline: false",
    `skill_under_test: ${q(skill)}`,
    "runner: atd-sandbox",
    `skills_loaded: [${q(skill)}]`,
    `description: ${q(description)}`,
    "tags: [discovery, atd]",
    "",
    "setup:",
    "  fixtures:",
    ...Object.entries(fixtures).map(([dest, src]) => `    ${q(dest)}: ${q(src)}`),
    "",
    "runner_config:",
    ...Object.entries(runnerConfig).filter(([, v]) => v !== undefined && v !== null).map(([k, v]) => `  ${k}: ${q(v)}`),
    "",
    "prompt: \"Not used: the atd-sandbox runner executes the candidate test and ignores this string.\"",
    "",
    "budget:",
    "  max_tokens: 1",
    `  max_seconds: ${runnerConfig.timeoutSeconds * 2 + 60}`,
    "",
    "checks:",
    "  - kind: discovery_finding",
    "    required: true",
    `    severity: ${severity}`,
    '    file: "atd-out/differential.json"',
    '    candidate_file: "candidate.json"',
    '    spec_file: "SPEC.md"',
    '    tests_dir: "tests"',
    "  - kind: discovery_test_health",
    "    required: false",
    '    file: "atd-out/differential.json"',
    "",
  ];
  return lines.join("\n");
}

// --- operator expectation reviews --------------------------------------------------------------------------

function loadApprovals(approvalDir, candidateIds, roundDir) {
  const out = { attached: [], rejected: [] };
  if (!approvalDir) return out;
  if (isInside(path.dirname(roundDir), realpathLoose(approvalDir))) {
    throw new UsageError("--approval-dir must be a trusted operator directory outside the discovery output directory");
  }
  for (const id of candidateIds) {
    const file = path.join(approvalDir, `${id}.expectation-review.json`);
    const stat = fs.lstatSync(file, { throwIfNoEntry: false });
    if (!stat) continue;
    if (!stat.isFile() || stat.size > MAX_APPROVAL_BYTES) {
      out.rejected.push({ candidateId: id, reason: "not a regular file within the size bound" });
      continue;
    }
    const bytes = fs.readFileSync(file);
    let parsed;
    try {
      parsed = JSON.parse(bytes.toString("utf8"));
    } catch {
      out.rejected.push({ candidateId: id, reason: "not valid JSON" });
      continue;
    }
    if (parsed?.candidateId !== id) {
      out.rejected.push({ candidateId: id, reason: "candidateId inside the review does not match" });
      continue;
    }
    const dest = path.join(roundDir, "approvals", `${id}.expectation-review.json`);
    writeTextExclusive(dest, bytes);
    out.attached.push({ candidateId: id, path: dest, sha256: sha256Hex(bytes), reviewer: typeof parsed.reviewer === "string" ? truncate(parsed.reviewer, 120) : null, verdict: parsed.verdict ?? null });
  }
  return out;
}

// --- harness execution ---------------------------------------------------------------------------------------

const TERM_GRACE_MS = 15000;

function killGroup(pid, signal) {
  try {
    process.kill(-pid, signal);
  } catch {
    // group already gone
  }
}

/**
 * Runs the existing harness in its OWN process group so a timeout (or an interrupt of this process) takes the whole
 * tree down: TERM first (the sandbox runner force-removes its containers on SIGTERM), KILL after a grace period,
 * and a final sweep for stragglers. The promise settles exactly once.
 */
function runHarness({ runSh, args, env, cwd, logDir, timeoutSeconds }) {
  fs.mkdirSync(logDir, { recursive: true });
  const stdoutFile = path.join(logDir, "run.stdout.log");
  const stderrFile = path.join(logDir, "run.stderr.log");
  const outFd = fs.openSync(stdoutFile, "wx");
  const errFd = fs.openSync(stderrFile, "wx");
  return new Promise(resolve => {
    const started = Date.now();
    let settled = false;
    let timedOut = false;
    let interrupted = null;
    let killTimer = null;
    const child = spawn("bash", [runSh, ...args], { cwd, env, stdio: ["ignore", outFd, errFd], detached: true });
    const stop = () => {
      if (child.pid === undefined) return;
      killGroup(child.pid, "SIGTERM");
      killTimer ??= setTimeout(() => killGroup(child.pid, "SIGKILL"), TERM_GRACE_MS);
    };
    const timer = setTimeout(() => { timedOut = true; stop(); }, timeoutSeconds * 1000);
    const onSignal = signal => { interrupted = signal; stop(); };
    process.once("SIGTERM", onSignal);
    process.once("SIGINT", onSignal);
    const settle = (code, error) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      clearTimeout(killTimer);
      process.removeListener("SIGTERM", onSignal);
      process.removeListener("SIGINT", onSignal);
      if (child.pid !== undefined) killGroup(child.pid, "SIGKILL");
      fs.closeSync(outFd);
      fs.closeSync(errFd);
      const stdout = fs.readFileSync(stdoutFile, "utf8");
      resolve({ exitCode: code, timedOut, interrupted, error, durationMs: Date.now() - started, stdoutFile, stderrFile, stdout });
    };
    child.on("error", error => settle(null, error.message));
    child.on("close", code => settle(code, null));
  });
}

function copyEvidence(source, dest) {
  fs.cpSync(source, dest, {
    recursive: true,
    dereference: false,
    filter: from => {
      if (from.split(path.sep).includes("node_modules")) return false;
      return !fs.lstatSync(from).isSymbolicLink();
    },
  });
}

// --- results consumption ---------------------------------------------------------------------------------------

export function consumeResults(results) {
  const cases = Array.isArray(results?.cases) ? results.cases : [];
  const counts = {};
  const consumed = cases.map(c => {
    const discovery = c.discovery && typeof c.discovery === "object" ? c.discovery : null;
    const status = typeof c.status === "string" ? c.status : c.passed === true ? "PASS" : "FAIL";
    const classification = discovery?.classification ?? (status === "PASS" ? "NO_FINDING" : "UNCLASSIFIED_NON_PASS");
    counts[classification] = (counts[classification] ?? 0) + 1;
    const failedChecks = (Array.isArray(c.checks) ? c.checks : [])
      .filter(k => (k.status ?? (k.passed ? "PASS" : "FAIL")) !== "PASS")
      .map(k => ({ kind: k.kind ?? null, status: k.status ?? "FAIL", failedCheckId: k.failed_check_id ?? null, hint: truncate(k.diff_hint ?? k.actual ?? null) }));
    return { caseId: c.case_id, status, classification, discovery, failedChecks, stability: c.stability ?? null, gradingManifest: c.grading_manifest ?? null };
  });
  const findings = consumed.filter(c => c.discovery).map(c => c.discovery);
  const nonPass = consumed.filter(c => c.status !== "PASS").map(c => ({ caseId: c.caseId, status: c.status, classification: c.classification, failedChecks: c.failedChecks }));
  return { cases: consumed, findings, nonPass, classificationCounts: counts };
}

// --- generation ------------------------------------------------------------------------------------------------

async function generateRound({ opts, roundDir, request, spec }) {
  const maxCalls = bounded(opts, "max-model-calls", 1, 1, 2);
  const transport = opts.transport ?? "omp";
  if (!["omp", "fixture"].includes(transport)) throw new UsageError("--transport must be omp or fixture");
  const calls = [];
  const common = { transport, real: transport === "omp", promptSha256: request.promptSha256, promptBytes: Buffer.byteLength(request.prompt), maxModelCalls: maxCalls };
  let selector = null;
  let modelRole = null;
  let version = null;
  if (transport === "omp") {
    const bin = opts["omp-bin"] ?? "omp";
    if (opts.model) {
      selector = opts.model;
      modelRole = "explicit";
    } else {
      selector = discoverRoleSelector({ bin, role: "implement" });
      modelRole = "implement";
    }
    const { model } = parseSelector(selector);
    const required = new RegExp(opts["require-model"] ?? "sonnet", "i");
    if (!required.test(model)) {
      throw new PipelineError("generation", "model_policy", `configured model '${model}' does not satisfy --require-model; no fallback model is used`);
    }
    version = ompVersion({ bin });
  } else if (!opts["fixture-response"]) {
    throw new UsageError("--transport=fixture requires --fixture-response=<file> (test seam only; not a real generation)");
  }

  let materialized = null;
  for (let call = 1; call <= maxCalls; call += 1) {
    const callDir = path.join(roundDir, "generation", `call-${call}`);
    fs.mkdirSync(callDir, { recursive: true });
    let record;
    if (transport === "omp") {
      record = await generateWithOmp({
        prompt: request.prompt,
        system: "You generate software test candidates as untrusted JSON data. You have no tools. Reply with exactly one JSON object in the response format given in the user message and nothing else.",
        selector,
        cwd: callDir,
        timeoutSeconds: bounded(opts, "generation-timeout", 900, 30, 3600),
        transcriptPath: path.join(callDir, "omp-events.jsonl"),
        bin: opts["omp-bin"] ?? "omp",
      });
      if (record.ok) {
        const { model } = parseSelector(selector);
        const stray = record.servedModels.filter(served => served !== model);
        if (record.servedModels.length === 0 || stray.length > 0) {
          record = { ...record, ok: false, error: `served model(s) [${record.servedModels.join(", ")}] differ from the configured ${model}; fallback or substitution is forbidden` };
        }
      }
    } else {
      const text = fs.readFileSync(opts["fixture-response"], "utf8");
      record = { ok: true, error: null, text, textSha256: sha256Hex(text), selector: "fixture", requestedModel: "fixture/none", thinking: null, servedModels: ["fixture/none"], usage: null, assistantMessages: 0, durationMs: 0, exitCode: 0, argv: null, transcriptPath: null, transcriptSha256: null };
    }
    const responsePath = path.join(callDir, "response.txt");
    fs.writeFileSync(responsePath, record.text ?? "", { flag: "wx" });
    const { text, ...rest } = record;
    const entry = { call, ...rest, responsePath, responseBytes: Buffer.byteLength(text ?? ""), outcome: "generated" };
    calls.push(entry);
    if (!record.ok) {
      entry.outcome = "failed";
      break;
    }
    const outDir = path.join(roundDir, "candidates");
    try {
      materialized = materializeCandidates({ request, response: text, outDir, modelId: record.servedModels[0] });
    } catch (error) {
      entry.outcome = "unparseable";
      entry.materializeError = truncate(String(error?.message ?? error), 400);
      continue;
    }
    entry.outcome = materialized.written.length > 0 ? "candidates_written" : "no_candidates";
    if (materialized.written.length > 0 || materialized.rejected.length > 0) break;
  }

  // An aggregate is reported only when EVERY call exposed a finite numeric value; one unknown makes the total unknown
  // (null), never a partial sum that reads as a complete one. Raw per-call values stay in calls[].usage.
  const sumUsage = key => {
    const values = calls.map(c => c.usage?.[key]);
    return values.length > 0 && values.every(v => typeof v === "number" && Number.isFinite(v)) ? values.reduce((a, v) => a + v, 0) : null;
  };
  const generation = {
    ...common,
    modelRole,
    selector,
    requestedModel: selector ? parseSelector(selector).model : null,
    thinking: selector ? parseSelector(selector).thinking : null,
    servedModels: [...new Set(calls.flatMap(c => c.servedModels ?? []))],
    modelRevision: null,
    modelRevisionNote: "OMP does not expose a provider model revision",
    ompVersion: version,
    modelCalls: calls.length,
    assistantMessages: calls.length > 0 && calls.every(c => Number.isFinite(c.assistantMessages)) ? calls.reduce((a, c) => a + c.assistantMessages, 0) : null,
    usage: { scope: "generation-call", input: sumUsage("input"), output: sumUsage("output"), cacheRead: sumUsage("cacheRead"), cacheWrite: sumUsage("cacheWrite"), costUsd: sumUsage("costUsd"), mainSessionUsage: null, mainSessionUsageNote: "coordinator session usage is not observable from this process" },
    durationMs: calls.reduce((a, c) => a + (c.durationMs ?? 0), 0),
    calls,
    specSha256: spec.sha256,
  };
  return { generation, materialized };
}

// --- one discovery round -----------------------------------------------------------------------------------------

export async function runRound(opts) {
  need(opts, "repo", "base", "candidate", "spec", "out");
  const framework = opts.framework ?? "vitest";
  if (!["vitest", "node:test"].includes(framework)) throw new UsageError("--framework must be vitest or node:test");
  const skill = opts.skill ?? "atd-discovery";
  const samples = bounded(opts, "stability-samples", 3, 3, 9);
  const maxCandidates = bounded(opts, "max-candidates", 12, 1, 25);
  const seed = bounded(opts, "seed", 1337, 0, 2147483647);
  const timeoutSeconds = bounded(opts, "timeout-seconds", 120, 5, 600);
  const customHarness = opts["eval-harness"] !== undefined;
  const runSh = opts["eval-harness"] ?? DEFAULT_RUN_SH;
  if (!fs.statSync(runSh, { throwIfNoEntry: false })?.isFile()) throw new UsageError(`eval-harness entrypoint not found: ${runSh}`);
  if (!fs.statSync(opts.repo, { throwIfNoEntry: false })?.isDirectory()) throw new UsageError(`--repo is not a directory: ${opts.repo}`);
  if (!fs.statSync(opts.spec, { throwIfNoEntry: false })?.isFile()) throw new UsageError(`--spec is not a file: ${opts.spec}`);
  const repoReal = fs.realpathSync(opts.repo);
  if (isInside(repoReal, realpathLoose(opts.out))) throw new UsageError("--out must be outside the repository under test (sources stay unmodified)");
  fs.mkdirSync(opts.out, { recursive: true });
  const outRoot = fs.realpathSync(opts.out);
  if (opts["state-dir"] && opts["state-dir"].includes(",")) throw new UsageError("--state-dir must not contain commas");
  if (outRoot.includes(",")) throw new UsageError("--out must not contain commas (run.sh --report syntax)");

  const baseCommit = resolveCommit(repoReal, opts.base, "--base");
  const candidateCommit = resolveCommit(repoReal, opts.candidate, "--candidate");
  checkDependencies(opts.dependencies, framework);
  if (opts.dependencies && isInside(outRoot, realpathLoose(opts.dependencies))) throw new UsageError("--dependencies must live outside the round output directory");

  let roundNumber = 1;
  for (const name of fs.readdirSync(outRoot)) {
    const m = /^round-(\d{3,})$/.exec(name);
    if (m) roundNumber = Math.max(roundNumber, Number(m[1]) + 1);
  }
  const roundName = `round-${String(roundNumber).padStart(3, "0")}`;
  const roundDir = path.join(outRoot, roundName);
  fs.mkdirSync(roundDir);

  const stateDir = opts["state-dir"] ?? process.env.EVAL_STATE_DIR ?? path.join(process.env.HOME ?? "", ".config", "opencode", "eval-harness");
  const summary = {
    schema: "atd.discovery-round/v1",
    status: "started",
    round: roundNumber,
    roundDir,
    startedAt: nowIso(),
    repository: repoReal,
    baseCommit,
    candidateCommit,
    framework,
    skill,
    limits: { maxModelCallsPerRound: opts["max-model-calls"] ?? 1, maxCandidates, stabilitySamples: samples, timeoutSeconds },
    stages: [],
    errors: [],
  };
  const stage = async (name, fn) => {
    const entry = { name, startedAt: nowIso(), durationMs: null, status: "running" };
    summary.stages.push(entry);
    const t0 = Date.now();
    try {
      const value = await fn();
      entry.status = "ok";
      return value;
    } catch (error) {
      entry.status = "error";
      throw error;
    } finally {
      entry.durationMs = Date.now() - t0;
    }
  };

  let exitCode = EXIT.ok;
  try {
    const spec = { path: path.join(roundDir, "spec", "SPEC.md") };
    fs.mkdirSync(path.dirname(spec.path));
    fs.copyFileSync(opts.spec, spec.path);
    spec.sha256 = sha256File(spec.path);
    summary.specSha256 = spec.sha256;

    const reused = opts.reevaluate ? path.resolve(opts.reevaluate) : null;
    if (reused && (!isInside(outRoot, realpathLoose(reused)) || !fs.statSync(path.join(reused, "candidates"), { throwIfNoEntry: false })?.isDirectory())) {
      throw new UsageError("--reevaluate must be an earlier round directory under --out");
    }
    let image = null;
    if (!customHarness) image = await stage("sandbox-preflight", () => preflightSandbox(opts.image));

    // 1. deterministic risk report + bounded request -------------------------------------------------
    const riskReport = await stage("risk", () => {
      const tracked = git(repoReal, ["ls-tree", "-r", "--name-only", candidateCommit]).split("\n").filter(Boolean);
      const existingTests = tracked.filter(f => /(^|\/)(tests?|__tests__)\//.test(f) || /\.(test|spec)\.[cm]?[jt]sx?$/.test(f));
      const report = analyzeChange({ repository: repoReal, baseCommit, candidateCommit, spec: spec.path, existingTests });
      writeJsonExclusive(path.join(roundDir, "risk.json"), report);
      return report;
    });
    summary.risk = { sha256: sha256File(path.join(roundDir, "risk.json")), diffSha256: riskReport.diffSha256 ?? null, targets: (riskReport.targets ?? []).length, skipped: (riskReport.skipped ?? []).length };

    const candidatesDir = path.join(roundDir, "candidates");
    const mutationReport = opts["mutation-report"] ? JSON.parse(fs.readFileSync(opts["mutation-report"], "utf8")) : null;
    let generation = null;
    // Frozen re-evaluation keeps the ORIGINAL proposal context: the mutant ids the model was shown come from the reused
    // round's own preserved generation-request.json, so mutation_guided candidates are still validated against them
    // without regenerating any mutation hint (and without any model call).
    let reusedMutantIds;
    let request = null;

    if (reused) {
      const originalSummary = readJsonIfPresent(path.join(reused, "round-summary.json"));
      const originalRequestFile = path.join(reused, "generation-request.json");
      const originalRequest = readJsonIfPresent(originalRequestFile);
      if (!originalRequest) {
        throw new UsageError("--reevaluate round has no preserved generation-request.json: the proposal context (prompt, mutants shown to the model) is part of its provenance, so re-evaluate from the original round instead");
      }
      if (originalRequest.baseCommit && (originalRequest.baseCommit !== baseCommit || originalRequest.candidateCommit !== candidateCommit)) {
        throw new UsageError("--reevaluate round was generated for different base/candidate commits than this run");
      }
      reusedMutantIds = Array.isArray(originalRequest.mutants) ? originalRequest.mutants.map(m => String(m.id)) : [];
      // The ORIGINAL proposal context travels with every replay, byte for byte, so a replay of a replay (or of a mutation-guided
      // round) keeps validating killsMutantIds against the mutants the model really saw. This is not a new generation.
      fs.copyFileSync(originalRequestFile, path.join(roundDir, "generation-request.json"), fs.constants.COPYFILE_EXCL);
      summary.request = {
        promptSha256: originalRequest.promptSha256 ?? null, diffSha256: originalRequest.diffSha256 ?? null, limits: originalRequest.limits ?? null,
        strategies: originalRequest.strategies ?? null, survivingMutantsProvided: reusedMutantIds.length, replayOfOriginalRequest: true,
      };
      const reusedSummarySha256 = fs.existsSync(path.join(reused, "round-summary.json")) ? sha256File(path.join(reused, "round-summary.json")) : null;
      // originalProvenance always names the ORIGINAL generation round: a replay of a replay keeps the prior original round and
      // only appends itself to replayChain.
      const prior = originalSummary?.generation?.originalProvenance ?? null;
      const originalProvenance = prior
        ? { ...prior, generationRequestSha256: sha256File(originalRequestFile), replayChain: [...(prior.replayChain ?? []), { round: originalSummary.round ?? null, summarySha256: reusedSummarySha256 }] }
        : {
          round: originalSummary?.round ?? null, summarySha256: reusedSummarySha256,
          promptSha256: originalSummary?.request?.promptSha256 ?? originalRequest.promptSha256 ?? null, generationRequestSha256: sha256File(originalRequestFile),
          strategies: originalRequest.strategies ?? originalSummary?.request?.strategies ?? null, mutantsShownToModel: reusedMutantIds.length,
          servedModels: originalSummary?.generation?.servedModels ?? null, modelCalls: originalSummary?.generation?.modelCalls ?? null, replayChain: [],
        };
      generation = {
        originalProvenance,
        transport: "reuse", real: false, reusedFrom: reused, modelCalls: 0, assistantMessages: 0, usage: { scope: "generation-call", input: null, output: null, cacheRead: null, cacheWrite: null, costUsd: null }, durationMs: 0 };
      await stage("reuse-candidates", () => {
        fs.mkdirSync(candidatesDir);
        for (const entry of fs.readdirSync(path.join(reused, "candidates"), { withFileTypes: true })) {
          if (entry.isDirectory() && SAFE_ID.test(entry.name)) copyEvidence(path.join(reused, "candidates", entry.name), path.join(candidatesDir, entry.name));
        }
      });
    } else if ((riskReport.targets ?? []).length === 0) {
      summary.status = "no_targets";
      summary.note = "no meaningful changed-source target; no model call was made and no behaviour claim is made";
      exitCode = EXIT.noCandidates;
    } else {
      request = await stage("request", () => {
        if (mutationReport) writeJsonExclusive(path.join(roundDir, "mutation-report.input.json"), mutationReport);
        const req = createGenerationRequest({
          riskReport, repository: repoReal, spec: spec.path, framework, limits: { maxCandidates }, mutationReport,
          generatorRole: mutationReport ? "mutation_guided_generator" : "intent_aware_generator",
        });
        writeJsonExclusive(path.join(roundDir, "generation-request.json"), req);
        writeTextExclusive(path.join(roundDir, "prompt.txt"), req.prompt);
        return req;
      });
      summary.request = { promptSha256: request.promptSha256, diffSha256: request.diffSha256 ?? riskReport.diffSha256 ?? null, limits: request.limits ?? null, strategies: request.strategies ?? null, survivingMutantsProvided: (request.mutants ?? []).length };
      const generated = await stage("generate", () => generateRound({ opts, roundDir, request, spec }));
      generation = generated.generation;
      summary.materialized = generated.materialized ? { written: generated.materialized.written.map(w => w.id), rejected: generated.materialized.rejected.map(r => ({ id: r.id ?? null, errors: r.errors })) } : null;
    }

    if (generation) {
      summary.generation = generation;
      writeJsonExclusive(path.join(roundDir, "generation.json"), generation);
    }
    if (generation && !reused && generation.calls.every(c => c.outcome === "failed")) {
      summary.status = "generation_failed";
      summary.errors.push({ stage: "generate", code: "generation_failed", message: generation.calls.map(c => c.error).filter(Boolean).join("; ") });
      exitCode = EXIT.generation;
    }

    // 2. validate -----------------------------------------------------------------------------------
    let accepted = [];
    if (exitCode === EXIT.ok && fs.existsSync(candidatesDir)) {
      const validation = await stage("validate", () => validateCandidateSet({
        candidatesDir, spec: spec.path, baseCommit, candidateCommit,
        sourceDiffHash: request?.diffSha256 ?? riskReport.diffSha256, riskReport, limits: { maxCandidates },
        ...(mutationReport ? { mutantIds: (mutationReport.gaps ?? []).map(g => String(g.id)) } : reusedMutantIds ? { mutantIds: reusedMutantIds } : {}),
      }));
      writeJsonExclusive(path.join(roundDir, "validation.json"), validation);
      accepted = validation.accepted ?? [];
      summary.candidates = {
        generatedByModel: summary.materialized ? summary.materialized.written.length + summary.materialized.rejected.length : null,
        accepted: accepted.length,
        rejected: (validation.rejected ?? []).map(r => ({ id: r.id ?? null, errors: (r.errors ?? []).map(e => ({ code: e.code, message: truncate(e.message, 300) })) })),
        counts: validation.counts ?? null,
        acceptedIds: accepted.map(a => a.id),
      };
    }
    if (exitCode === EXIT.ok && accepted.length === 0) {
      summary.status = "no_candidates";
      summary.note = "generation produced no candidate that passed deterministic validation; nothing was executed";
      exitCode = EXIT.noCandidates;
    }

    // 3. cases + existing harness ----------------------------------------------------------------------
    if (exitCode === EXIT.ok) {
      const skillsRoot = path.join(roundDir, "skills-root");
      const casesDir = path.join(skillsRoot, skill, "evals", "cases");
      fs.mkdirSync(casesDir, { recursive: true });
      const approvals = loadApprovals(opts["approval-dir"], accepted.map(a => a.id), roundDir);
      summary.approvals = approvals;
      const approvedIds = new Set(approvals.attached.map(a => a.candidateId));
      const targetSeverity = file => (riskReport.targets ?? []).find(t => t.file === file)?.riskLevel ?? "medium";
      const caseFiles = [];
      await stage("materialize-cases", () => {
        for (const entry of accepted) {
          const candidate = entry.candidate;
          const candidateJson = path.join(entry.dir, "candidate.json");
          const testPath = path.join(entry.dir, "tests", candidate.testFile);
          if (!fs.lstatSync(testPath).isFile() || !fs.lstatSync(candidateJson).isFile()) throw new PipelineError("materialize-cases", "bad_candidate_files", `${candidate.id}: candidate files must be regular files`);
          const fixtures = { "SPEC.md": spec.path, "candidate.json": candidateJson, [`tests/${candidate.testFile}`]: testPath };
          if (approvedIds.has(candidate.id)) fixtures["expectation-review.json"] = path.join(roundDir, "approvals", `${candidate.id}.expectation-review.json`);
          const runnerConfig = {
            repository: repoReal, baseCommit, candidateCommit, candidateFile: "candidate.json", testsDir: "tests", testsRel: ".", specFile: "SPEC.md",
            dependencies: opts.dependencies, image: opts.image, seed, timeoutSeconds,
          };
          const yaml = renderCaseYaml({
            skill, candidate, severity: targetSeverity(candidate.targetFile), runnerConfig, fixtures,
            description: `discovery candidate ${candidate.id} (${candidate.strategy}) for ${candidate.targetFile}: ${truncate(candidate.failureHypothesis ?? "", 160)}`,
          });
          const file = path.join(casesDir, `${candidate.id}.yaml`);
          writeTextExclusive(file, yaml);
          caseFiles.push(file);
        }
        const review = path.join(roundDir, "review");
        for (const entry of accepted) {
          const candidate = entry.candidate;
          writeJsonExclusive(path.join(review, `${candidate.id}.expectation-review.template.json`), {
            schema_version: 1,
            note: "OPERATOR TEMPLATE. Read the generated test and SPEC.md, then set verdict (PASS|FAIL), reviewer, rubric_version, timestamp and rationale, and save it as <candidateId>.expectation-review.json in a trusted directory passed as --approval-dir. Bindings below must equal the signed attestation values.",
            candidateId: candidate.id,
            testSha256: candidate.testSha256,
            specSha256: spec.sha256,
            candidateManifestSha256: sha256File(path.join(entry.dir, "candidate.json")),
            testPath: path.join(entry.dir, "tests", candidate.testFile),
            verdict: null, reviewer: null, rubric_version: null, timestamp: null, rationale: null,
          });
        }
      });

      const env = { ...process.env, OPENCODE_SKILLS_ROOT: skillsRoot, EVAL_STATE_DIR: stateDir, EVAL_SKIP_AUTH_CHECK: "1" };
      for (const key of ["EVAL_RUNNER", "EVAL_AB_MODEL_OVERRIDE", "EVAL_BYPASS", "EVAL_REPORTS", "EVAL_STRICT", "EVAL_MODE"]) delete env[key];
      const reportsDir = path.join(roundDir, "reports");
      fs.mkdirSync(reportsDir);
      const junit = path.join(reportsDir, "discovery.junit.xml");
      const sarif = path.join(reportsDir, "discovery.sarif.json");
      const args = [`--skill=${skill}`, "--trigger=manual", "--mode=full", `--stability-samples=${samples}`, `--report=junit:${junit}`, `--report=sarif:${sarif}`];
      const harnessTimeout = opts["harness-timeout"] ?? Math.min(7200, 300 + accepted.length * (samples + 1) * timeoutSeconds * 2);
      const harness = await stage("harness", () => runHarness({ runSh, args, env, cwd: roundDir, logDir: path.join(roundDir, "logs"), timeoutSeconds: harnessTimeout }));
      const runIdMatch = /\brun_id=(\S+)/.exec(harness.stdout);
      const runId = runIdMatch?.[1] ?? null;
      const runDir = runId ? path.join(stateDir, "runs", runId) : null;
      const resultsPath = runDir ? path.join(runDir, "results.json") : null;
      summary.harness = {
        runSh, args: ["bash", runSh, ...args], exitCode: harness.exitCode, timedOut: harness.timedOut, interrupted: harness.interrupted, error: harness.error, durationMs: harness.durationMs,
        runId, runDir, stdoutLog: harness.stdoutFile, stderrLog: harness.stderrFile, image,
        reports: { junit: fs.existsSync(junit) ? junit : null, sarif: fs.existsSync(sarif) ? sarif : null },
      };

      if (!resultsPath || !fs.existsSync(resultsPath)) {
        summary.status = "harness_error";
        summary.errors.push({ stage: "harness", code: harness.timedOut ? "harness_timeout" : "no_results", message: `eval-harness exit ${harness.exitCode}; results.json was not produced` });
        exitCode = EXIT.harness;
      } else {
        const resultsRaw = fs.readFileSync(resultsPath);
        const results = JSON.parse(resultsRaw.toString("utf8"));
        fs.copyFileSync(resultsPath, path.join(roundDir, "results.json"));
        if (fs.existsSync(path.join(runDir, "diff.md"))) fs.copyFileSync(path.join(runDir, "diff.md"), path.join(roundDir, "diff.md"));
        const evidenceDir = path.join(roundDir, "evidence");
        for (const c of results.cases ?? []) {
          if (SAFE_ID.test(c.case_id ?? "") && fs.existsSync(path.join(runDir, c.case_id))) copyEvidence(path.join(runDir, c.case_id), path.join(evidenceDir, c.case_id));
        }
        const consumed = consumeResults(results);
        // results.json is only a claim. Replay every finding/non-PASS case through the existing grade.sh on its
        // preserved grading manifest; signer trust and eligibility come ONLY from that replay.
        const recomputed = await stage("verify-evidence", async () => recomputeRound({ results, evidenceRoot: evidenceDir, stateDir, approvalDir: opts["approval-dir"] ?? null, untrustedRoots: [outRoot, roundDir] }));
        Object.assign(summary.harness, { verdict: results.verdict ?? null, summary: results.summary ?? null, resultsPath, resultsSha256: sha256Hex(resultsRaw), schemaVersion: results.schema_version ?? null, stateDir });
        summary.cases = consumed.cases.map(({ discovery, ...rest }) => ({ ...rest, findingId: discovery?.findingId ?? null }));
        summary.findings = consumed.findings;
        summary.rawFindingsNote = "findings[] is the raw cases[].discovery from results.json (a claim). recomputedFindings[] is authoritative.";
        summary.nonPass = consumed.nonPass;
        summary.classificationCounts = consumed.classificationCounts;
        summary.verification = {
          tool: "scripts/eval/grade.sh (preserved grading manifest replay)", stateDir, replayedCases: recomputed.length,
          cases: recomputed.map(e => ({ caseId: e.caseId, recomputed: e.recomputed, consistent: e.consistent, reason: e.reason, rawClassification: e.rawClassification, classification: e.classification ?? null, trust: e.trust ?? null, independent: e.independent })),
        };
        summary.recomputedFindings = recomputed.filter(e => e.finding).map(e => e.finding);
        summary.recomputedClassificationCounts = recomputed.reduce((acc, e) => { const k = e.recomputed ? (e.classification ?? "NO_FINDING") : "UNVERIFIED"; acc[k] = (acc[k] ?? 0) + 1; return acc; }, {});
        summary.verifiedIndependentFindingIds = recomputed.filter(e => e.independent).map(e => e.finding.findingId ?? e.caseId);
        for (const e of recomputed.filter(x => !x.recomputed || !x.consistent)) {
          summary.errors.push({ stage: "verify", code: e.recomputed ? "results_inconsistent" : "evidence_not_verified", message: `${e.caseId}: ${e.reason}` });
        }
        summary.status = harness.exitCode === 13 || results.verdict === "ERROR" ? "harness_error" : "completed";
        if (summary.status === "harness_error") {
          summary.errors.push({ stage: "harness", code: "harness_error", message: `eval-harness verdict ${results.verdict ?? "unknown"} (exit ${harness.exitCode})` });
          exitCode = EXIT.harness;
        }
        const reproducer = path.join(roundDir, "reproduce.sh");
        writeTextExclusive(reproducer, [
          "#!/usr/bin/env bash",
          "# Re-runs one discovery case through the same existing eval-harness + atd-sandbox path (confined; never on the host).",
          "set -euo pipefail",
          'CASE_ID="${1:?usage: reproduce.sh <caseId>}"',
          `export OPENCODE_SKILLS_ROOT=${shellQuote(skillsRoot)}`,
          `export EVAL_STATE_DIR=${shellQuote(stateDir)}`,
          "export EVAL_SKIP_AUTH_CHECK=1",
          `exec bash ${shellQuote(runSh)} --skill=${shellQuote(skill)} --case="$CASE_ID" --trigger=manual --mode=full --stability-samples=${samples}`,
          "",
        ].join("\n"), 0o755);
        summary.reproducer = reproducer;
      }
    }
  } catch (error) {
    if (error instanceof UsageError) {
      summary.status = "usage_error";
      summary.errors.push({ stage: "input", code: "usage", message: error.message });
      exitCode = EXIT.usage;
    } else {
      const stageName = error instanceof PipelineError ? error.stage : "pipeline";
      summary.status = error instanceof PipelineError
        ? ({ preflight: "preflight_failed", generation: "generation_failed" }[error.stage] ?? "harness_error")
        : "harness_error";
      summary.errors.push({ stage: stageName, code: error.code ?? "error", message: truncate(String(error?.message ?? error), 800) });
      exitCode = error instanceof PipelineError && stageName === "generation" ? EXIT.generation : EXIT.harness;
    }
  }

  summary.endedAt = nowIso();
  summary.exitCode = exitCode;
  const summaryPath = path.join(roundDir, "round-summary.json");
  writeJsonExclusive(summaryPath, summary);
  fs.appendFileSync(path.join(outRoot, "rounds.ndjson"), `${JSON.stringify({ round: roundNumber, status: summary.status, summaryPath, summarySha256: sha256File(summaryPath), at: summary.endedAt })}\n`);
  return { summary, summaryPath, exitCode };
}

// --- entry point -----------------------------------------------------------------------------------------------

async function main(argv) {
  const { opts, positional } = parseOptions(argv);
  const command = positional[0] ?? "run";
  if (positional.length > 1) throw new UsageError(`unexpected argument '${positional[1]}'`);
  if (command === "mutation-evidence") {
    const { runMutationEvidence } = await import("./run-mutation.mjs");
    return runMutationEvidence(opts);
  }
  if (command === "pilot-snapshot" || command === "pilot-report") {
    need(opts, "out");
    const report = await import("./workflow-report.mjs");
    if (command === "pilot-snapshot") {
      need(opts, "name");
      process.stdout.write(`ATD_PILOT_SNAPSHOT=${report.pilotSnapshot({ out: opts.out, name: opts.name })}\n`);
    } else {
      const { file } = report.pilotReport({ out: opts.out, mutationBaselineDir: opts["mutation-baseline"], mutationWithDir: opts["mutation-with"], stateDir: opts["state-dir"] });
      process.stdout.write(`ATD_PILOT_REPORT=${file}\n`);
    }
    return 0;
  }
  if (command !== "run") throw new UsageError(`unknown command '${command}' (run | mutation-evidence)`);
  const { summary, summaryPath, exitCode } = await runRound(opts);
  if (opts.json) process.stdout.write(`${JSON.stringify(summary, null, 2)}\n`);
  process.stdout.write(`ATD_STATUS=${summary.status}\nATD_SUMMARY=${summaryPath}\n`);
  if (exitCode !== EXIT.ok) for (const e of summary.errors) process.stderr.write(`[atd] ${e.stage}/${e.code}: ${e.message}\n`);
  return exitCode;
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main(process.argv.slice(2)).then(
    code => { process.exitCode = code ?? 0; },
    error => {
      process.stderr.write(`[atd] ${error instanceof UsageError ? "usage" : "fatal"}: ${error?.message ?? error}\n`);
      process.exitCode = error instanceof UsageError ? EXIT.usage : EXIT.harness;
    },
  );
}
