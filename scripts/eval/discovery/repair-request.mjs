#!/usr/bin/env node
// repair-request.mjs — turn VERIFIED, independently attested regressions into bounded, distinct repair
// requests for Jev's existing repair loop (budget.maxRepairRounds). No Jev code is touched.
//
//   node repair-request.mjs --results=<results.json> [--evidence-root=<dir>] [--ledger-dir=<dir>]
//        [--candidate-commit=<sha>] [--max-attempts=3] [--max-requests=3] [--state-dir=<EVAL_STATE_DIR of the run>]
//
// results.json is only a CLAIM. Every case with a finding or a non-PASS status is replayed through the existing
// scripts/eval/grade.sh on its preserved, content-addressed grading manifest (workflow-verify.mjs), which verifies the
// digests and the runner signature, recomputes the matrix and finalizes the finding. Only that recomputed answer
// (and its signer trust) can produce a request; a missing manifest/signature, a tampered artifact or stability
// record, or a results.json that disagrees with the replay yields no request. Output also carries
// `verification` (per-case replay record) and `independentVerified` (what a blocking gate may rely on).
// Eligible (becomes a repair request and consumes an attempt): classification VERIFIED_REGRESSION AND
// valid signed evidence AND reproducible (stability-bound) AND spec support established AND an attestation
// trust of ci-secret or separate-user. A VERIFIED finding with only local-same-user trust is reported as
// an advisory (never a repair request). SUSPECTED/INCONCLUSIVE/EXPECTED_CHANGE/EXISTING_FAILURE are never
// repaired. Attempts per (targetFile, requirement quote) are capped; the capped regression becomes a
// human-review record. Requests are written exclusively (never overwritten); the ledger is append-only.

import { createHash } from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { INDEPENDENT_TRUST, recomputeRound } from "./workflow-verify.mjs";
const EXCERPT_LIMIT = 4096;
const MAX_EVIDENCE_READ = 4 * 1024 * 1024;
const sha256 = data => createHash("sha256").update(data).digest("hex");

class UsageError extends Error {}

/** Truncates to a byte bound without splitting a UTF-8 sequence; strips ANSI/control characters. */
export function boundExcerpt(text, limit = EXCERPT_LIMIT) {
  // eslint-disable-next-line no-control-regex
  const clean = String(text).replace(/\u001b\[[0-9;?]*[ -/]*[@-~]/g, "").replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f]/g, "");
  let buf = Buffer.from(clean, "utf8");
  if (buf.length <= limit) return clean;
  buf = buf.subarray(0, limit);
  let end = buf.length;
  while (end > 0 && (buf[end - 1] & 0xc0) === 0x80) end -= 1;
  if (end > 0 && buf[end - 1] >= 0xc0) end -= 1;
  return `${buf.subarray(0, end).toString("utf8")}\n[truncated]`;
}

function readConfined(root, relative) {
  if (typeof relative !== "string" || relative === "" || path.isAbsolute(relative) || relative.split(/[\\/]/).includes("..")) return null;
  const full = path.resolve(root, relative);
  let real;
  try {
    real = fs.realpathSync(full);
    const rootReal = fs.realpathSync(root);
    const rel = path.relative(rootReal, real);
    if (rel.startsWith("..") || path.isAbsolute(rel)) return null;
    const stat = fs.statSync(real);
    if (!stat.isFile() || stat.size > MAX_EVIDENCE_READ) return null;
    return fs.readFileSync(real, "utf8");
  } catch {
    return null;
  }
}

function excerptFromVitest(text) {
  try {
    const parsed = JSON.parse(text);
    const lines = [];
    for (const file of parsed.testResults ?? []) {
      for (const t of file.assertionResults ?? []) {
        if (t.status === "failed") lines.push(`${t.fullName ?? t.title ?? "test"}: ${(t.failureMessages ?? []).join("\n")}`);
      }
      if (file.status === "failed" && (file.assertionResults ?? []).length === 0 && file.message) lines.push(String(file.message));
    }
    return lines.length ? lines.join("\n\n") : null;
  } catch {
    return null;
  }
}

/** Reads the candidate-side failure evidence listed by the finding (run-dir-relative, confined). */
export function failureExcerpt(finding, evidenceRoot) {
  const uris = Array.isArray(finding.evidenceUris) ? finding.evidenceUris : [];
  const candidateSide = uris.filter(u => /(^|\/)artifacts\//.test(u) && path.basename(u).startsWith("candidate"));
  const order = [/vitest|json$/i, /junit|xml$/i, /stderr/i, /stdout/i];
  const rank = u => { const i = order.findIndex(r => r.test(u)); return i === -1 ? order.length : i; };
  const ranked = [...candidateSide].sort((a, b) => rank(a) - rank(b));
  for (const uri of ranked) {
    const text = readConfined(evidenceRoot, uri);
    if (text === null) continue;
    const structured = /json$/i.test(uri) ? excerptFromVitest(text) : null;
    return { text: boundExcerpt(structured ?? text), source: uri };
  }
  return { text: "", source: null };
}

function readCandidateManifest(finding, evidenceRoot) {
  const caseId = finding.caseId ?? finding.candidateId;
  const text = readConfined(evidenceRoot, `${caseId}/workdir/candidate.json`);
  try {
    return text ? JSON.parse(text) : null;
  } catch {
    return null;
  }
}

function regressionKey(targetFile, quote) {
  return sha256(`${targetFile}\n${quote}`);
}

class LedgerCorrupt extends Error {}

/** Attempt accounting must never reset silently: any malformed non-empty row fails the whole read (fail closed). */
function readLedger(file) {
  if (!fs.existsSync(file)) return [];
  const rows = [];
  fs.readFileSync(file, "utf8").split("\n").forEach((line, index) => {
    if (line.trim() === "") return;
    let row;
    try {
      row = JSON.parse(line);
    } catch {
      throw new LedgerCorrupt(`ledger_corrupt: ${file} line ${index + 1} is not valid JSON; refusing to continue (attempt accounting would reset). Repair or archive the ledger manually.`);
    }
    if (!row || typeof row !== "object" || typeof row.regressionKey !== "string" || !["issued", "exhausted"].includes(row.status)) {
      throw new LedgerCorrupt(`ledger_corrupt: ${file} line ${index + 1} is not a valid ledger record; refusing to continue.`);
    }
    rows.push(row);
  });
  return rows;
}

export function buildRepairRequests({
  resultsPath, evidenceRoot, ledgerDir, candidateCommit = null, maxAttempts = 3, maxRequests = 3,
  gradeSh, stateDir, approvalDir = null, env = process.env, now = () => new Date().toISOString(),
}) {
  if (!Number.isInteger(maxAttempts) || maxAttempts < 1 || maxAttempts > 10) throw new UsageError("--max-attempts must be 1..10");
  if (!Number.isInteger(maxRequests) || maxRequests < 1 || maxRequests > 10) throw new UsageError("--max-requests must be 1..10");
  const raw = fs.readFileSync(resultsPath);
  const results = JSON.parse(raw.toString("utf8"));
  const resultsSha256 = sha256(raw);
  const root = evidenceRoot ?? (fs.existsSync(path.join(path.dirname(resultsPath), "evidence")) ? path.join(path.dirname(resultsPath), "evidence") : path.dirname(resultsPath));
  fs.mkdirSync(ledgerDir, { recursive: true });
  const ledgerFile = path.join(ledgerDir, "ledger.ndjson");
  const ledger = readLedger(ledgerFile);

  // Nothing in results.json is trusted: every case with a finding or a non-PASS status is replayed through the
  // existing grade.sh on its preserved grading manifest, and only the replayed answer can make a request.
  const entries = recomputeRound({ results, evidenceRoot: root, gradeSh, stateDir, env, approvalDir, untrustedRoots: [path.dirname(resultsPath), ledgerDir] });
  const out = {
    schema: "atd.repair-recommendation/v1", resultsSha256, ehRunId: results.run_id ?? null, generatedAt: now(), maxAttempts, maxRequests,
    verification: {
      tool: "scripts/eval/grade.sh (preserved grading manifest replay)", stateDir: stateDir ?? null, replayedCases: entries.length,
      cases: entries.map(e => ({
        caseId: e.caseId, recomputed: e.recomputed, consistent: e.consistent, reason: e.reason, rawStatus: e.rawStatus, rawClassification: e.rawClassification, rawTrust: e.rawTrust,
        gradeStatus: e.gradeStatus ?? null, classification: e.classification ?? null, trust: e.trust ?? null, independent: e.independent, independentBlockedReason: e.independentBlockedReason ?? null,
        finding: e.finding ? {
          findingId: e.finding.findingId ?? null, severity: e.finding.severity ?? null, targetFile: e.finding.targetFile ?? null, testFile: e.finding.testFile ?? null, matrix: e.finding.matrix ?? null,
          reproducible: e.finding.reproducible ?? null, requirementSupported: e.finding.requirementSupported ?? null, evidenceStatus: e.finding.evidenceStatus ?? null,
          explanation: typeof e.finding.explanation === "string" ? e.finding.explanation.slice(0, 400) : null, reproducer: e.finding.reproducer ?? null, evidenceUris: (e.finding.evidenceUris ?? []).slice(0, 5),
        } : null,
      })),
    },
    independentVerified: entries.filter(e => e.independent && (!candidateCommit || e.finding?.candidateCommit === candidateCommit)).map(e => ({ findingId: e.finding.findingId, caseId: e.caseId, targetFile: e.finding.targetFile, trust: e.trust })),
    requests: [], advisories: [], exhausted: [], skipped: [], humanReviewRequired: false,
  };
  const seenKeys = new Set();

  for (const entry of entries) {
    const finding = entry.finding;
    const id = finding?.findingId ?? entry.caseId;
    if (!entry.recomputed) {
      out.skipped.push({ findingId: id, classification: entry.rawClassification, reason: `not independently verified: ${entry.reason}` });
      if (entry.rawClassification === "VERIFIED_REGRESSION") out.humanReviewRequired = true;
      continue;
    }
    if (!entry.consistent) {
      out.skipped.push({ findingId: id, classification: entry.classification, reason: entry.reason });
      out.humanReviewRequired = true;
      continue;
    }
    if (!finding || finding.classification !== "VERIFIED_REGRESSION") {
      if (finding) out.skipped.push({ findingId: id, classification: finding.classification ?? null, reason: "only VERIFIED_REGRESSION findings are repair candidates" });
      continue;
    }
    const gaps = [];
    if (finding.evidenceStatus !== "valid") gaps.push("evidence is not valid");
    if (finding.reproducible !== true) gaps.push("not reproducible under stability sampling");
    if (finding.requirementSupported !== true) gaps.push("spec support is not established");
    if (gaps.length) {
      out.skipped.push({ findingId: id, classification: finding.classification, reason: gaps.join("; ") });
      continue;
    }
    const manifest = readCandidateManifest({ ...finding, caseId: entry.caseId }, root);
    const quote = manifest?.requirementRef?.quote ?? null;
    const specSha256 = manifest?.requirementRef?.specSha256 ?? null;
    if (!quote || !specSha256) {
      out.skipped.push({ findingId: id, classification: finding.classification, reason: "candidate requirement reference unavailable in preserved evidence" });
      continue;
    }
    const trust = finding.attestation?.trust ?? null;
    const key = regressionKey(finding.targetFile, quote);
    // The attested revision is never rewritten: evidence for another commit is stale for this evaluation and spends no attempt.
    const attestedCommit = typeof finding.candidateCommit === "string" && finding.candidateCommit !== "" ? finding.candidateCommit : null;
    if (candidateCommit && attestedCommit !== candidateCommit) {
      out.skipped.push({ findingId: id, classification: finding.classification, reason: `stale_evidence: the evidence is attested for candidate commit ${attestedCommit ?? "(none)"} but the commit under evaluation is ${candidateCommit}; no repair request was made and no attempt was spent` });
      out.humanReviewRequired = true;
      continue;
    }
    if (seenKeys.has(key)) {
      out.skipped.push({ findingId: id, classification: finding.classification, reason: "duplicate of another finding for the same target file and requirement in this run" });
      continue;
    }
    seenKeys.add(key);
    const excerpt = failureExcerpt(finding, root);
    const commit = attestedCommit;
    const body = {
      schema: "atd.repair-request/v1",
      findingId: id,
      ehRunId: results.run_id ?? null,
      resultsSha256,
      classification: "VERIFIED_REGRESSION",
      targetFile: finding.targetFile,
      reproducer: finding.reproducer ?? null,
      failureExcerpt: excerpt.text,
      failureExcerptSource: excerpt.source,
      requirementRef: { specSha256, quote },
      regressionKey: key,
      candidateId: finding.candidateId ?? null,
      baseCommit: finding.sourceCommit ?? null,
      candidateCommit: commit,
      attestationTrust: trust,
      instruction: `Restore the behaviour required by the quoted requirement in ${finding.targetFile}. The reproducer passed on the base revision and failed on the candidate revision in a confined sandbox. Fix the production source only; do not edit, delete or skip the generated test.`,
    };

    if (!entry.independent) {
      const why = !INDEPENDENT_TRUST.has(trust)
        ? `attestation trust '${trust}' is not independent`
        : `independent signer but ${entry.independentBlockedReason ?? "the operator review could not be confirmed against a trusted approvalDir"}`;
      out.advisories.push({ ...body, eligibleForRepairLoop: false, reason: `${why}; recorded for human review only` });
      out.humanReviewRequired = true;
      continue;
    }

    const prior = ledger.filter(e => e.regressionKey === key);
    const sameCommit = prior.find(e => e.status === "issued" && e.candidateCommit === commit);
    // The per-run request cap bounds what this invocation hands out, whether the request is reused from the ledger or newly issued.
    const capReached = out.requests.length >= maxRequests;
    if (sameCommit) {
      if (capReached) {
        out.skipped.push({ findingId: id, classification: finding.classification, reason: `per-run request cap (${maxRequests}) reached; an already issued request was not handed out again` });
        continue;
      }
      out.requests.push({ path: sameCommit.requestPath, request: JSON.parse(fs.readFileSync(sameCommit.requestPath, "utf8")), reused: true });
      continue;
    }
    const attemptsUsed = new Set(prior.filter(e => e.status === "issued").map(e => e.candidateCommit)).size;
    if (attemptsUsed >= maxAttempts) {
      const record = { regressionKey: key, status: "exhausted", findingId: id, attempts: attemptsUsed, maxAttempts, candidateCommit: commit, at: now() };
      if (!prior.some(e => e.status === "exhausted" && e.candidateCommit === commit)) fs.appendFileSync(ledgerFile, `${JSON.stringify(record)}\n`);
      out.exhausted.push({ findingId: id, targetFile: finding.targetFile, regressionKey: key, attempts: attemptsUsed, maxAttempts, reason: "repair attempts exhausted; human review required" });
      out.humanReviewRequired = true;
      continue;
    }
    if (capReached) {
      out.skipped.push({ findingId: id, classification: finding.classification, reason: `per-run request cap (${maxRequests}) reached` });
      continue;
    }
    const attempt = attemptsUsed + 1;
    const request = { ...body, attempt, maxAttempts };
    const requestPath = path.join(ledgerDir, `repair-${key.slice(0, 12)}-a${attempt}.json`);
    fs.writeFileSync(requestPath, `${JSON.stringify(request, null, 2)}\n`, { flag: "wx" });
    fs.appendFileSync(ledgerFile, `${JSON.stringify({ regressionKey: key, status: "issued", attempt, findingId: id, candidateCommit: commit, requestPath, requestSha256: sha256(fs.readFileSync(requestPath)), at: now() })}\n`);
    out.requests.push({ path: requestPath, request, reused: false });
  }
  return out;
}

function parseArgs(argv) {
  const opts = {};
  for (const arg of argv) {
    const m = /^--([a-z-]+)(?:=(.*))?$/.exec(arg);
    if (!m) throw new UsageError(`unexpected argument '${arg}'`);
    opts[m[1]] = m[2] ?? true;
  }
  return opts;
}

function main(argv) {
  const opts = parseArgs(argv);
  const allowed = new Set(["results", "evidence-root", "ledger-dir", "candidate-commit", "max-attempts", "max-requests", "state-dir", "approval-dir", "json"]);
  for (const k of Object.keys(opts)) if (!allowed.has(k)) throw new UsageError(`unknown option --${k}`);
  if (typeof opts.results !== "string") throw new UsageError("--results=<results.json> is required");
  const resultsPath = path.resolve(opts.results);
  const recommendation = buildRepairRequests({
    resultsPath,
    evidenceRoot: typeof opts["evidence-root"] === "string" ? path.resolve(opts["evidence-root"]) : undefined,
    ledgerDir: path.resolve(typeof opts["ledger-dir"] === "string" ? opts["ledger-dir"] : path.join(path.dirname(resultsPath), "repair")),
    candidateCommit: typeof opts["candidate-commit"] === "string" ? opts["candidate-commit"] : null,
    maxAttempts: opts["max-attempts"] === undefined ? 3 : Number(opts["max-attempts"]),
    maxRequests: opts["max-requests"] === undefined ? 3 : Number(opts["max-requests"]),
    approvalDir: typeof opts["approval-dir"] === "string" && opts["approval-dir"] !== "" ? path.resolve(opts["approval-dir"]) : null,
    stateDir: typeof opts["state-dir"] === "string" && opts["state-dir"] !== "" ? path.resolve(opts["state-dir"]) : process.env.EVAL_STATE_DIR ?? path.join(process.env.HOME ?? "", ".config", "opencode", "eval-harness"),
  });
  process.stdout.write(`${JSON.stringify(recommendation, null, 2)}\n`);
  return 0;
}

const isMain = (() => { try { return Boolean(process.argv[1]) && fs.realpathSync(process.argv[1]) === fs.realpathSync(fileURLToPath(import.meta.url)); } catch { return false; } })();
if (isMain) {
  try {
    process.exitCode = main(process.argv.slice(2));
  } catch (error) {
    process.stderr.write(`[atd-repair] ${error?.message ?? error}\n`);
    process.exitCode = error instanceof UsageError ? 2 : 13;
  }
}
