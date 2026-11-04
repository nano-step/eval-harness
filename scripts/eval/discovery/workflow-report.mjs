// workflow-report.mjs — `run.mjs pilot-snapshot` and `run.mjs pilot-report`.
//
// Pure readers of artifacts the real pipeline produced (round summaries, harness results, mutation evidence).
// Nothing is estimated: a metric with no measurement is null with a reason, and rates are always reported as
// numerator/denominator with an explicit scope. They describe THIS pilot execution only (one benchmark, one
// change per scenario, one model): no detection or false-positive rate is generalized from them.
//
// Counting rules: only rounds with a real generation call count as generation/model usage (a review replay
// contributes zero); candidate identity is (scenario, original generation round, candidate id), so replay does not double-count.
// Findings are taken from the independent grade.sh recomputation recorded in each round summary; a raw
// results.json claim without a recomputation is reported with basis "raw-unverified" and never counted as confirmed.

import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { compareRaw, environmentDiffs, readSealedArtifacts, summarizeRawReport, treeSha256, verifyMutationSeal } from "./run-mutation.mjs";
import { normalizeStrykerReport } from "./mutation.mjs";

const sha256 = data => createHash("sha256").update(data).digest("hex");
const REGRESSION_CLASSES = new Set(["VERIFIED_REGRESSION", "SUSPECTED_REGRESSION"]);

const git = (repo, args) => execFileSync("git", ["-C", repo, ...args], { encoding: "utf8", maxBuffer: 64 * 1024 * 1024, env: { ...process.env, GIT_TERMINAL_PROMPT: "0" } });
const readJson = file => JSON.parse(fs.readFileSync(file, "utf8"));
const exists = file => fs.existsSync(file);

function fixtureOf(pilotOut) {
  const file = path.join(pilotOut, "fixture", "fixture.json");
  if (!exists(file)) throw new Error(`fixture description not found: ${file}`);
  return readJson(file);
}

function fixtureCommits(fixture) {
  return { base: fixture.baseCommit, clean: fixture.revisions.clean.commit, boundaryDefect: fixture.revisions.boundaryDefect.commit, zeroSizeDefect: fixture.revisions.zeroSizeDefect.commit };
}

export function pilotSnapshot({ out, name }) {
  if (!["before", "after"].includes(name)) throw new Error("--name must be before or after");
  const fixture = fixtureOf(out);
  const repo = fixture.repository;
  const commits = {};
  for (const [label, commit] of Object.entries(fixtureCommits(fixture))) {
    commits[label] = { commit, tree: git(repo, ["rev-parse", `${commit}^{tree}`]).trim() };
  }
  const tracked = git(repo, ["ls-files", "-z"]).split("\0").filter(Boolean);
  const snapshot = {
    schema: "atd.pilot-integrity/v1", name, at: new Date().toISOString(), repository: repo, commits,
    refs: git(repo, ["for-each-ref", "--format=%(refname) %(objectname)"]).trim().split("\n").sort(),
    head: git(repo, ["symbolic-ref", "-q", "HEAD"]).trim(),
    statusPorcelain: git(repo, ["status", "--porcelain", "--untracked-files=all"]).trim(),
    checkedOutFiles: Object.fromEntries(tracked.map(f => [f, sha256(fs.readFileSync(path.join(repo, f)))])),
  };
  const file = path.join(out, `integrity-${name}.json`);
  fs.writeFileSync(file, `${JSON.stringify(snapshot, null, 2)}\n`, { flag: "wx" });
  return file;
}

// --- numeric helpers (null + reason, never a fabricated zero) -------------------------------------------------------

// A total is reported only when every observation is a finite number; any unknown makes it unknown (null), never a partial sum.
const sumOrNull = values => (values.length > 0 && values.every(v => typeof v === "number" && Number.isFinite(v)) ? values.reduce((a, b) => a + b, 0) : null);

const ratio = (numerator, denominator, scope) => ({
  numerator, denominator, scope,
  rate: denominator > 0 ? Math.round((numerator / denominator) * 10000) / 10000 : null,
  ...(denominator > 0 ? {} : { reason: "denominator is zero: nothing of this kind was observed" }),
});

function nearestRank(sorted, p) {
  return sorted[Math.min(sorted.length - 1, Math.max(0, Math.ceil(p * sorted.length) - 1))];
}

function distribution(values, unit, scope) {
  const numbers = values.filter(v => typeof v === "number" && Number.isFinite(v)).sort((a, b) => a - b);
  if (numbers.length === 0) return { count: 0, unit, scope, median: null, p95: null, min: null, max: null, reason: "no observation recorded" };
  const mid = numbers.length % 2 ? numbers[(numbers.length - 1) / 2] : (numbers[numbers.length / 2 - 1] + numbers[numbers.length / 2]) / 2;
  return { count: numbers.length, unit, scope, median: mid, p95: nearestRank(numbers, 0.95), min: numbers[0], max: numbers[numbers.length - 1], method: "median; p95 by nearest rank" };
}

// --- round loading ----------------------------------------------------------------------------------------------------

function loadRounds(pilotOut, scenario) {
  const dir = path.join(pilotOut, scenario);
  if (!exists(dir)) return [];
  return fs.readdirSync(dir).filter(n => /^round-\d+$/.test(n)).sort().flatMap(n => {
    const file = path.join(dir, n, "round-summary.json");
    if (!exists(file)) return [];
    const resultsFile = path.join(dir, n, "results.json");
    return [{ scenario, name: n, dir: path.join(dir, n), file, sha256: sha256(fs.readFileSync(file)), summary: readJson(file), results: exists(resultsFile) ? readJson(resultsFile) : null }];
  });
}

const isReal = r => r.summary.generation?.real === true;
const isReplay = r => r.summary.generation?.transport === "reuse";

function roundMetrics(r) {
  const s = r.summary;
  return {
    round: s.round, status: s.status, summaryPath: r.file, summarySha256: r.sha256,
    generation: s.generation ? {
      transport: s.generation.transport, real: s.generation.real, selector: s.generation.selector ?? null, servedModels: s.generation.servedModels ?? [],
      modelCalls: s.generation.modelCalls ?? null, assistantMessages: s.generation.assistantMessages ?? null, usage: s.generation.usage ?? null,
      durationMs: s.generation.durationMs ?? null, promptSha256: s.generation.promptSha256 ?? null, reusedFrom: s.generation.reusedFrom ?? null,
    } : null,
    strategies: s.request?.strategies ?? null, survivingMutantsProvided: s.request?.survivingMutantsProvided ?? null,
    candidates: s.candidates ? { generatedByModel: s.candidates.generatedByModel ?? null, accepted: s.candidates.accepted, rejected: (s.candidates.rejected ?? []).length, rejectionCodes: s.candidates.counts?.byCode ?? null } : null,
    harness: s.harness ? { verdict: s.harness.verdict ?? null, exitCode: s.harness.exitCode ?? null, durationMs: s.harness.durationMs ?? null, runId: s.harness.runId ?? null, resultsSha256: s.harness.resultsSha256 ?? null } : null,
    classificationCounts: s.classificationCounts ?? null,
    recomputedClassificationCounts: s.recomputedClassificationCounts ?? null,
    verification: s.verification ? { replayedCases: s.verification.replayedCases, cases: s.verification.cases } : null,
    cases: (s.cases ?? []).map(c => ({ caseId: c.caseId, status: c.status, classification: c.classification, stability: c.stability ? { performed: c.stability.performed ?? null, samples: c.stability.samples ?? null, byteIdentical: c.stability.byte_identical ?? null } : null })),
    nonPass: s.nonPass ?? [], errors: s.errors ?? [],
    reviewTemplates: s.status === "completed" ? path.join(path.dirname(r.file), "review") : null,
    approvals: s.approvals ?? null,
  };
}

function mutationSide(dir, { commit, repo, stateDir, baseline }) {
  if (!exists(dir)) return null;
  const unavailable = reason => ({ evidencePath: path.join(dir, "evidence.json"), status: "unavailable", reason, counts: null, score: null, comparison: null });
  try {
    const config = fs.readFileSync(path.join(dir, "stryker.config.json"));
    const plan = readJson(path.join(dir, "plan.json"));
    if (`${JSON.stringify(plan.strykerConfig, null, 2)}\n` !== config.toString("utf8") || plan.candidateCommit !== commit) return unavailable("plan/configuration does not match the candidate revision");
    const testsDir = path.join(dir, "accepted-tests");
    if (!baseline && fs.readdirSync(testsDir).length === 0) return unavailable("the signed generated-tests tree is empty");
    const tests = baseline ? sha256("") : treeSha256(testsDir);
    const sandbox = path.join(dir, "sandbox");
    const seal = verifyMutationSeal(sandbox, { stateDir, expect: { commit, configSha256: sha256(config), testsTreeSha256: tests, maxMutants: plan.maxMutants } });
    if (!seal.ok) return unavailable(seal.reason);
    if (seal.record.outcome !== "pass" || seal.record.exitCode !== 0 || seal.record.timedOut || seal.record.mutationBudget?.allowed !== true) return unavailable("signed mutation execution did not pass within budget");
    const { report } = readSealedArtifacts(sandbox, seal.record);
    if (!report) return unavailable("signed mutation report is missing");
    const normalized = normalizeStrykerReport(report.json, { repository: repo, candidateCommit: commit, plan });
    if (normalized.sourcePreserved !== true) return unavailable("signed report sources could not be verified against the revision");
    const raw = summarizeRawReport(report.json);
    const side = {
      evidencePath: path.join(dir, "evidence.json"), label: baseline ? "baseline" : "with-generated-tests",
      status: "measured", outcome: seal.record.outcome, counts: raw.counts, score: raw.score, scoreFormula: raw.scoreFormula,
      acceptedTests: baseline ? [] : Object.keys(report.json.testFiles ?? {}).filter(f => exists(path.join(dir, "accepted-tests", f))),
      executionRecord: { executionId: seal.record.executionId, durationMs: seal.record.durationMs ?? null },
      reportSha256: report.sha256, seal: { status: "valid", trust: seal.trust, attestationSha256: seal.attestationSha256 },
      survivingMutants: raw.mutants.filter(m => m.status === "Survived" || m.status === "NoCoverage"),
    };
    Object.defineProperty(side, "_verified", { value: { seal, raw, configSha256: sha256(config) } });
    return side;
  } catch (error) {
    return unavailable(error.message);
  }
}

/** Findings of one round: the independent recomputation when it ran, else the raw claim flagged as unverified. */
function findingsOf(round) {
  const s = round.summary;
  const verified = (s.verification?.cases ?? []).filter(c => c.recomputed && c.consistent).map(c => ({ caseId: c.caseId, origin: originOf(round), classification: c.classification, trust: c.trust, basis: "recomputed" }));
  const seen = new Set(verified.map(v => v.caseId));
  const raw = (s.cases ?? []).filter(c => !seen.has(c.caseId) && c.classification && !["NO_FINDING", "UNCLASSIFIED_NON_PASS"].includes(c.classification)).map(c => ({ caseId: c.caseId, origin: originOf(round), classification: c.classification, trust: null, basis: "raw-unverified" }));
  return [...verified.filter(v => v.classification), ...raw];
}

// Candidate identity is (scenario, ORIGINAL generation round, id). Ids repeat across different generation rounds with different test
// bytes (e.g. two proposals both named "touching-edges-corners"), so they must not collapse into one candidate; a replay round
// re-evaluates the candidates of the round it reuses, so it maps back to the canonical original round recorded in its
// originalProvenance (a replay of a replay keeps the first original) and is still not double counted.
const roundName = n => `round-${String(n).padStart(3, "0")}`;
const originOf = r => {
  if (!isReplay(r)) return r.name;
  const original = r.summary.generation?.originalProvenance?.round;
  if (Number.isInteger(original)) return roundName(original);
  return typeof r.summary.generation?.reusedFrom === "string" ? path.basename(r.summary.generation.reusedFrom) : r.name;
};
/** The latest execution of each original proposal set (primary or any replay); earlier rounds stay in the history. */
const latestPerOrigin = rounds => [...new Map(rounds.map(r => [originOf(r), r])).values()];
const key = (r, id) => `${r.scenario}:${originOf(r)}:${id}`;

export function pilotReport({ out, mutationBaselineDir, mutationWithDir, stateDir = path.join(out, "eval-state") }) {
  const fixture = fixtureOf(out);
  const clean = loadRounds(out, "clean");
  const defect = loadRounds(out, "defect");
  const all = [...clean, ...defect];
  const commit = fixture.revisions.clean.commit;
  const mutationBaseline = mutationSide(mutationBaselineDir ?? path.join(out, "mutation", "baseline"), { commit, repo: fixture.repository, stateDir, baseline: true });
  const mutationWith = mutationSide(mutationWithDir ?? path.join(out, "mutation", "with-generated-tests"), { commit, repo: fixture.repository, stateDir, baseline: false });
  if (mutationBaseline?._verified && mutationWith?._verified) {
    const a = mutationBaseline._verified;
    const b = mutationWith._verified;
    const diffs = environmentDiffs(a.seal.record, b.seal.record);
    if (a.configSha256 !== b.configSha256) diffs.push({ field: "configSha256" });
    if (!a.seal.attestation.runner?.scriptSha256 || a.seal.attestation.runner.scriptSha256 !== b.seal.attestation.runner?.scriptSha256) diffs.push({ field: "runner.scriptSha256" });
    if (diffs.length === 0) mutationWith.comparison = { ...compareRaw(a.raw, b.raw), baselineScore: a.raw.score };
    else mutationWith.comparisonUnavailable = { reason: "signed environments differ", diffs };
  }
  const realRounds = all.filter(isReal);
  const replayRounds = all.filter(isReplay);

  // --- generation -------------------------------------------------------------------------------------------------------
  const usageSum = k => sumOrNull(realRounds.map(r => r.summary.generation?.usage?.[k] ?? null));
  const generation = {
    scope: "real OMP generation calls made by the pipeline only (replay rounds re-evaluate existing candidates and contribute no call)",
    realRounds: realRounds.length, replayRounds: replayRounds.length,
    modelCalls: sumOrNull(realRounds.map(r => r.summary.generation?.modelCalls ?? null)),
    assistantMessages: sumOrNull(realRounds.map(r => r.summary.generation?.assistantMessages ?? null)),
    successRate: ratio(realRounds.filter(r => r.summary.status !== "generation_failed" && (r.summary.materialized?.written?.length ?? 0) > 0).length, realRounds.length, "real generation rounds whose call succeeded and produced at least one parseable candidate"),
    usage: { scope: "generation calls only", input: usageSum("input"), output: usageSum("output"), cacheRead: usageSum("cacheRead"), cacheWrite: usageSum("cacheWrite"), costUsd: usageSum("costUsd") },
    mainSessionUsage: null, workerInclusiveUsage: null,
    usageNote: "OMP per-call usage is the only observable source; coordinator (main-session) and worker-inclusive totals are not observable from the pipeline and are reported as null, never inferred",
    latencyMs: distribution(realRounds.map(r => r.summary.generation?.durationMs ?? null), "ms", "wall time of one generation round (all of its model calls)"),
  };

  // --- candidates, static acceptance vs operator approval -----------------------------------------------------------
  const staticAccepted = new Set();
  const executed = new Set();
  const approvals = new Map();
  const approvalsInvalid = new Set();
  const scenariosWithReview = new Set();
  for (const r of all) {
    for (const id of r.summary.candidates?.acceptedIds ?? []) staticAccepted.add(key(r, id));
    for (const c of r.summary.cases ?? []) executed.add(key(r, c.caseId));
    for (const a of r.summary.approvals?.attached ?? []) { approvals.set(key(r, a.candidateId), a); scenariosWithReview.add(r.scenario); }
    for (const a of r.summary.approvals?.rejected ?? []) approvalsInvalid.add(key(r, a.candidateId));
  }
  const approvedPass = [...approvals.values()].filter(a => a.verdict === "PASS").length;
  const approvedFail = [...approvals.values()].filter(a => a.verdict === "FAIL").length;
  const acceptedInReviewedScenarios = [...staticAccepted].filter(k => scenariosWithReview.has(k.split(":")[0])).length;
  const latestPerScenario = ["clean", "defect"].map(s => [...all.filter(r => r.scenario === s)].pop()).filter(Boolean);
  const pendingReview = latestPerScenario.reduce((n, r) => n + findingsOf(r).filter(f => f.classification === "SUSPECTED_REGRESSION").length, 0);
  const candidates = {
    scope: "unique (scenario, original generation round, candidate id); replays map back to their original round and are not double-counted",
    generatedByModel: sumOrNull(realRounds.map(r => r.summary.candidates?.generatedByModel ?? null)),
    staticallyAccepted: staticAccepted.size,
    staticallyRejected: sumOrNull(realRounds.map(r => (r.summary.candidates?.rejected ?? []).length)),
    executedInSandbox: executed.size,
    operatorApproved: approvedPass, operatorRejected: approvedFail, operatorReviewInvalid: approvalsInvalid.size,
    operatorAcceptedRate: scenariosWithReview.size
      ? ratio(approvedPass, acceptedInReviewedScenarios, "operator-approved (review verdict PASS) over statically accepted candidates of the scenarios where a review was supplied")
      : { numerator: null, denominator: null, rate: null, reason: "no operator review has been supplied yet; static validation is not operator acceptance" },
    persisted: 0,
    persistedNote: "generated tests are provisional evidence only; nothing is written to the repository under test or to any baseline",
  };
  const humanReview = {
    reviewsSupplied: approvals.size, reviewsInvalid: approvalsInvalid.size, approvedPass, rejected: approvedFail,
    pendingReviewSuspectedFindings: pendingReview,
    reviewTemplatesIssued: staticAccepted.size,
  };

  // --- detection and false positives (pilot scope) ----------------------------------------------------------------------
  const defectFindings = defect.flatMap(r => findingsOf(r));
  const cleanFindings = clean.flatMap(r => findingsOf(r));
  const defectRealRound = defect.some(isReal);
  const detectedAny = defectFindings.some(f => REGRESSION_CLASSES.has(f.classification));
  const confirmedRecomputed = defectFindings.some(f => f.classification === "VERIFIED_REGRESSION" && f.basis === "recomputed");
  const confirmedIndependent = defectFindings.some(f => f.classification === "VERIFIED_REGRESSION" && f.basis === "recomputed" && ["ci-secret", "separate-user"].includes(f.trust));
  const cleanRealRound = clean.some(isReal);
  const cleanRegressionCases = new Set(cleanFindings.filter(f => REGRESSION_CLASSES.has(f.classification)).map(f => `${f.origin}:${f.caseId}`));
  const cleanExecuted = [...executed].filter(k => k.startsWith("clean:")).length;
  // Latest execution per original proposal set (history above is kept; these two numbers describe where the proposals ended up).
  const cleanLatest = latestPerOrigin(clean);
  const cleanLatestRegressionCases = new Set(cleanLatest.flatMap(r => findingsOf(r)).filter(f => REGRESSION_CLASSES.has(f.classification)).map(f => `${f.origin}:${f.caseId}`));
  const cleanLatestExecuted = new Set(cleanLatest.flatMap(r => (r.summary.cases ?? []).map(c => key(r, c.caseId)))).size;
  const realGenerations = { clean: clean.filter(isReal).length, defect: defect.filter(isReal).length };
  const detection = {
    scope: "pilot only: one clean change and one injected boundary defect; not a general detection or false-positive rate",
    findingBasis: "independent grade.sh recomputation of preserved evidence (raw results.json claims are never counted as confirmed)",
    injectedDefects: { distinct: defectRealRound ? 1 : 0 },
    detectionAny: ratio(defectRealRound && detectedAny ? 1 : 0, defectRealRound ? 1 : 0, "unique injected defects with at least one PASS->FAIL regression finding (suspected or verified)"),
    confirmedDetection: ratio(defectRealRound && confirmedRecomputed ? 1 : 0, defectRealRound ? 1 : 0, "unique injected defects with a recomputed VERIFIED_REGRESSION (any signer trust; needs the operator expectation review)"),
    confirmedIndependentDetection: ratio(defectRealRound && confirmedIndependent ? 1 : 0, defectRealRound ? 1 : 0, "as above with a ci-secret or separate-user signer"),
    falsePositiveChangeLevel: ratio(cleanRealRound && cleanRegressionCases.size > 0 ? 1 : 0, cleanRealRound ? 1 : 0, "RAW HISTORY: unique clean changes where ANY clean round execution ever produced a suspected or verified regression finding"),
    falsePositiveCandidateLevel: ratio(cleanRegressionCases.size, cleanExecuted, "RAW HISTORY: unique clean-change candidate tests that ever produced a regression finding"),
    falsePositiveChangeLevelLatest: ratio(cleanRealRound && cleanLatestRegressionCases.size > 0 ? 1 : 0, cleanRealRound ? 1 : 0, "LATEST EXECUTION: unique clean changes where the latest execution of an original proposal set produced a suspected or verified regression finding (earlier rounds stay in the history above)"),
    falsePositiveCandidateLevelLatest: ratio(cleanLatestRegressionCases.size, cleanLatestExecuted, "LATEST EXECUTION: unique clean-change candidate tests whose latest execution produced a regression finding"),
    caveat: `n=1 change per scenario; ${realGenerations.clean} real clean and ${realGenerations.defect} real defect generation call(s) with the same model, nondeterministic: these counts show what happened in this pilot and have no statistical power`,
  };

  // --- mutation ----------------------------------------------------------------------------------------------------------
  const cmp = mutationWith?.comparison ?? null;
  const mutation = {
    scope: "StrykerJS inside the atd-sandbox on the clean revision, scoped to the changed ranges",
    baselineScore: mutationBaseline?.score ?? null, scoreWithGeneratedTests: mutationWith?.score ?? null,
    baselineCounts: mutationBaseline?.counts ?? null, withGeneratedCounts: mutationWith?.counts ?? null,
    unmatchedBaselineMutants: cmp?.unmatchedBeforeMutants ?? null,
    killRateOfBaselineSurvivors: cmp ? ratio(cmp.killedAfterSurvivalBefore, cmp.survivedBefore, "mutants that survived the baseline tests and were killed once the accepted generated tests were added (same signed runner, environment and Stryker config)") : { numerator: null, denominator: null, rate: null, reason: mutationWith?.comparisonUnavailable?.reason ?? (mutationWith?.reason || "no comparable signed mutation runs") },
    scoreFormula: mutationBaseline?.scoreFormula ?? null,
    refusals: [mutationBaseline, mutationWith].filter(m => m?.status === "refused" || m?.status === "unavailable").map(m => ({ label: m.label, reason: m.reason, refusal: m.refusal })),
  };

  // --- flakiness and latency --------------------------------------------------------------------------------------------
  const sampled = new Map();
  for (const r of all) for (const c of r.summary.cases ?? []) if (c.stability?.performed === true) sampled.set(key(r, c.caseId), c.stability);
  const flaky = [...sampled.values()].filter(s => s.byte_identical === false).length;
  const flakiness = {
    ...ratio(flaky, sampled.size, "unique cases that failed their primary run and were re-executed in fresh containers (>= 3 samples); flaky = samples diverged"),
    minSamplesObserved: sampled.size ? Math.min(...[...sampled.values()].map(s => s.samples ?? 0)) : null,
  };
  const caseDurations = all.flatMap(r => (r.results?.cases ?? []).map(c => c.duration_ms));
  const latency = {
    harnessCase: distribution(caseDurations, "ms", "wall time of one harness case: primary sandbox execution, its fresh stability samples and grading"),
    harnessRound: distribution(all.map(r => r.summary.harness?.durationMs ?? null), "ms", "wall time of one run.sh invocation (all cases of the round)"),
    mutationRun: distribution([mutationBaseline, mutationWith].map(m => m?.executionRecord?.durationMs ?? null), "ms", "wall time of one confined Stryker run"),
    generation: generation.latencyMs,
  };

  // --- cost per unique verified injected defect ---------------------------------------------------------------------------
  const defectCost = sumOrNull(defect.filter(isReal).map(r => r.summary.generation?.usage?.costUsd ?? null));
  const pilotCost = generation.usage.costUsd;
  const costPerVerifiedDefect = {
    scope: "generation cost of the injected-defect scenario divided by unique injected defects with a recomputed VERIFIED_REGRESSION",
    defectScenarioGenerationCostUsd: defectCost, pilotTotalGenerationCostUsd: pilotCost,
    uniqueVerifiedDefects: defectRealRound && confirmedRecomputed ? 1 : 0,
    costUsdPerVerifiedDefect: defectRealRound && confirmedRecomputed && defectCost !== null ? defectCost : null,
    reason: !(defectRealRound && confirmedRecomputed) ? "no verified injected defect yet (needs the operator expectation review and replay)" : defectCost === null ? "OMP did not expose per-call cost" : null,
  };

  // --- expectations -------------------------------------------------------------------------------------------------------
  let integrity = null;
  const beforeFile = path.join(out, "integrity-before.json");
  const afterFile = path.join(out, "integrity-after.json");
  if (exists(beforeFile) && exists(afterFile)) {
    const before = readJson(beforeFile);
    const after = readJson(afterFile);
    const same = JSON.stringify([before.commits, before.refs, before.head, before.checkedOutFiles]) === JSON.stringify([after.commits, after.refs, after.head, after.checkedOutFiles]);
    integrity = { before: beforeFile, after: afterFile, commitsRefsAndFilesIdentical: same, workingTreeClean: after.statusPorcelain === "", statusPorcelainAfter: after.statusPorcelain };
  }
  // Acceptance uses the LATEST execution of the SAME original proposal set (primary or review/fresh replays); every earlier round,
  // including failed or indeterminate ones, stays visible in `history`, and a different generation is never a replacement.
  const cleanOrigin = clean.find(r => isReal(r) && !r.summary.request?.survivingMutantsProvided) ?? null;
  const cleanIntent = cleanOrigin ? [...clean].reverse().find(r => originOf(r) === originOf(cleanOrigin)) : null;
  const cleanHistory = cleanOrigin ? clean.filter(r => originOf(r) === originOf(cleanOrigin)).map(r => ({ round: r.summary.round, transport: r.summary.generation?.transport ?? null, status: r.summary.status, nonPass: (r.summary.nonPass ?? []).length, errors: (r.summary.errors ?? []).map(e => `${e.stage}/${e.code}`) })) : [];
  const cleanIntentFindings = cleanIntent ? findingsOf(cleanIntent) : [];
  const defectLatest = latestPerOrigin(defect);
  const failingCases = defectLatest.flatMap(r => (r.summary.cases ?? []).filter(c => c.status !== "PASS"));
  const expectations = [
    {
      id: "clean_change_not_flagged", description: "the latest execution of the original clean-change proposals produced no regression finding and no non-PASS case",
      met: cleanIntent && cleanIntent.summary.status === "completed" ? cleanIntentFindings.filter(f => REGRESSION_CLASSES.has(f.classification)).length === 0 && cleanIntent.summary.nonPass.length === 0 : null,
      evidence: cleanIntent ? { origin: originOf(cleanOrigin), latestRound: cleanIntent.summary.round, status: cleanIntent.summary.status, casesExecuted: (cleanIntent.summary.cases ?? []).length, history: cleanHistory } : "no completed clean round",
    },
    {
      id: "injected_regression_detected", description: "at least one accepted generated test passed on the base and failed on the injected boundary defect in the sandbox",
      met: defectRealRound && defect.find(isReal).summary.status === "completed" ? detectedAny : null,
      evidence: defectFindings.filter(f => REGRESSION_CLASSES.has(f.classification)),
    },
    {
      id: "injected_regression_verified", description: "the detection reached a RECOMPUTED VERIFIED_REGRESSION (needs an operator expectation review bound to the signed hashes plus 3 stable fresh samples)",
      met: confirmedRecomputed ? true : replayRounds.some(r => r.scenario === "defect") ? false : null,
      evidence: confirmedRecomputed ? defectFindings.filter(f => f.classification === "VERIFIED_REGRESSION") : replayRounds.some(r => r.scenario === "defect") ? "review replay completed without a recomputed VERIFIED_REGRESSION" : "pending operator expectation review (findings stay SUSPECTED by design)",
    },
    {
      id: "defect_evidence_stable", description: "each failing case was re-executed in fresh containers (stability performed, >= 3 samples)",
      met: failingCases.length === 0 ? null : failingCases.every(c => c.stability?.performed === true && (c.stability?.samples ?? 0) >= 3),
      evidence: failingCases.map(c => ({ caseId: c.caseId, stability: c.stability })),
    },
    {
      id: "baseline_gap_survives", description: "Stryker reports at least one surviving or uncovered mutant for the baseline tests on the changed ranges",
      met: mutationBaseline?.counts ? mutationBaseline.counts.survived + mutationBaseline.counts.noCoverage > 0 : null,
      evidence: mutationBaseline ? { counts: mutationBaseline.counts, score: mutationBaseline.score } : "mutation baseline not run",
    },
    {
      id: "gap_killed_by_accepted_generated_test", description: "a mutant that survived the baseline tests was killed once accepted generated tests were added (same config, same commit)",
      met: cmp ? cmp.killedAfterSurvivalBefore > 0 : null,
      evidence: cmp ? { killed: cmp.killedAfterSurvivalBefore, survivedBefore: cmp.survivedBefore, scoreBefore: cmp.baselineScore, scoreAfter: mutationWith.score, acceptedTests: mutationWith.acceptedTests } : "with-generated-tests run not performed",
    },
    {
      id: "original_sources_unchanged", description: "the fixture repository (commits, refs, checked-out files) is byte-identical after the pilot and the working tree is clean",
      met: integrity ? integrity.commitsRefsAndFilesIdentical && integrity.workingTreeClean : null,
      evidence: integrity ?? "integrity snapshots missing",
    },
  ];

  const report = {
    schema: "atd.pilot-report/v1",
    generatedAt: new Date().toISOString(),
    benchmark: { name: "collision (modelled on axis-aligned rectangle collision; not part of img2pixi2d; nothing here is deployed)", repository: fixture.repository, commits: fixtureCommits(fixture) },
    environment: fixture.environment ?? null,
    scenarios: {
      clean: { rounds: clean.map(roundMetrics) },
      defect: { rounds: defect.map(roundMetrics), reviewReplayed: replayRounds.some(r => r.scenario === "defect") },
      mutation: { baseline: mutationBaseline, withGeneratedTests: mutationWith },
    },
    metrics: { generation, candidates, humanReview, detection, mutation, flakiness, latency, costPerVerifiedDefect },
    expectations,
    integrity,
    limitations: [
      `single benchmark and model; small sample (${realGenerations.clean} real clean and ${realGenerations.defect} real defect generation call(s)); model output is nondeterministic and a rerun can differ`,
      "false-positive and detection numbers labelled RAW HISTORY include every round ever executed; the LATEST EXECUTION variants and the acceptance expectations use the latest execution of each original proposal set while earlier failures stay in the history",
      "findings remain SUSPECTED until an operator expectation review bound to the signed test/spec hashes is supplied",
      "local attestations are same-user evidence (reporting only); CONFIRMED/blocking needs an independent signer",
      "main-session and worker-inclusive usage totals are not observable from the pipeline and stay null",
    ],
  };
  const file = path.join(out, "pilot-report.json");
  const target = fs.existsSync(file) ? path.join(out, `pilot-report.${Date.now()}.json`) : file;
  fs.writeFileSync(target, `${JSON.stringify(report, null, 2)}\n`, { flag: "wx" });
  return { file: target, report };
}
