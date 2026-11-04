// workflow-verify.mjs — independent recomputation of discovery findings from PRESERVED evidence.
//
// results.json and round summaries are plain JSON that anyone with file access could edit, so nothing in them
// (classification, trust label, evidenceStatus, reproducible, requirementSupported) is ever promoted to a
// repair request, a blocking decision, or a QA CONFIRMED_DEFECT on its own. Every case that carries a finding
// (or any non-PASS status) is replayed through the EXISTING `scripts/eval/grade.sh` on its preserved,
// content-addressed grading manifest. That replay verifies the manifest digests (workdir, case, stability
// samples, atd evidence), verifies the runner's signature with atd_verify (signer trust comes from the
// verifier's key material, never from the JSON), recomputes the differential and finalizes the finding with
// the same finalizer the live run uses. There is no second verifier here: this file only drives grade.sh and
// compares its answer with what results.json claims.
//
// Two boundaries exist because the preserved manifest, case.yaml and review file are only hash-bound, not signed
// (an attacker who can write them can rewrite the manifest too):
//   1. Before any replay, the preserved case definition must be exactly what this workflow generates: runner
//      atd-sandbox and only discovery_finding / discovery_test_health checks with the default file bindings. An
//      injected check of any other kind (for example a `shell` check with unsafe_shell) is refused and grade.sh is
//      never run on it, so nothing attacker-chosen executes on the host.
//   2. Independent promotion additionally needs the operator's ORIGINAL expectation review from an explicit TRUSTED
//      approvalDir supplied by the caller (CLI/config, never read from results or summaries and never inside the
//      round/output/evidence directories). Its exact bytes must equal the review that supported the recomputed
//      finding; the review's own bindings to the attested candidate/test/spec/manifest hashes are enforced by the
//      grader. Without it a VERIFIED finding stays an advisory.

import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
export const DEFAULT_GRADE_SH = path.resolve(HERE, "..", "grade.sh");
const YQ_SHIM = path.resolve(HERE, "..", "lib", "yq-shim.sh");
export const INDEPENDENT_TRUST = new Set(["ci-secret", "separate-user"]);
const SAFE_ID = /^[A-Za-z0-9][A-Za-z0-9._-]*$/;
const MAX_GRADE_OUTPUT = 16 * 1024 * 1024;
const MAX_REVIEW_BYTES = 16 * 1024;
const sha256 = data => createHash("sha256").update(data).digest("hex");

const ALLOWED_CHECK_KEYS = {
  discovery_finding: new Set(["kind", "required", "severity", "file", "candidate_file", "spec_file", "tests_dir"]),
  discovery_test_health: new Set(["kind", "required", "file"]),
};
const DEFAULT_BINDINGS = { file: "atd-out/differential.json", candidate_file: "candidate.json", spec_file: "SPEC.md", tests_dir: "tests" };

function isInside(parent, child) {
  const rel = path.relative(parent, child);
  return rel === "" || (!rel.startsWith("..") && !path.isAbsolute(rel));
}

/** The preserved case definition must be the generated discovery case: no other grader may run on the host. */
export function inspectCaseDefinition(caseDir) {
  const caseFile = path.join(caseDir, "case.yaml");
  if (!fs.existsSync(caseFile)) return { ok: false, reason: "preserved case.yaml is missing" };
  const run = spawnSync("bash", ["-c", 'source "$1" && yq -o=json "." "$2"', "inspect", YQ_SHIM, caseFile], { encoding: "utf8", timeout: 30000, maxBuffer: 1024 * 1024 });
  let doc;
  try {
    doc = JSON.parse(run.stdout);
  } catch {
    return { ok: false, reason: "preserved case.yaml could not be parsed" };
  }
  if (run.status !== 0 || !doc || typeof doc !== "object") return { ok: false, reason: "preserved case.yaml could not be parsed" };
  if (doc.runner !== "atd-sandbox") return { ok: false, reason: `case runner '${doc.runner}' is not atd-sandbox` };
  if (doc.mode !== undefined && doc.mode !== "deterministic") return { ok: false, reason: "case mode is not deterministic" };
  if (!Array.isArray(doc.checks) || doc.checks.length === 0) return { ok: false, reason: "case has no checks" };
  for (const check of doc.checks) {
    const allowed = ALLOWED_CHECK_KEYS[check?.kind];
    if (!allowed) return { ok: false, reason: `check kind '${check?.kind}' is outside the discovery allowlist (discovery_finding, discovery_test_health); it is never executed` };
    for (const [k, v] of Object.entries(check)) {
      if (!allowed.has(k)) return { ok: false, reason: `check key '${k}' is outside the generated case shape` };
      if (k in DEFAULT_BINDINGS && v !== DEFAULT_BINDINGS[k]) return { ok: false, reason: `check ${k} must be the default binding '${DEFAULT_BINDINGS[k]}'` };
      if (k === "required" && typeof v !== "boolean") return { ok: false, reason: "check required must be boolean" };
      if (k === "severity" && !["low", "medium", "high"].includes(v)) return { ok: false, reason: "check severity must be low, medium or high" };
    }
  }
  return { ok: true };
}

/** Exact-byte comparison of the supporting review with the operator's original in a trusted directory. */
export function checkTrustedReview({ caseDir, candidateId, approvalDir, untrustedRoots = [] }) {
  if (!approvalDir) return { ok: false, reason: "no trusted approvalDir was supplied: independent promotion needs the operator's original expectation review" };
  if (typeof candidateId !== "string" || !SAFE_ID.test(candidateId)) return { ok: false, reason: "candidate id is not a safe file name" };
  let realApprovals;
  try {
    realApprovals = fs.realpathSync(approvalDir);
  } catch {
    return { ok: false, reason: "trusted approvalDir does not exist" };
  }
  for (const root of untrustedRoots) {
    let real;
    try { real = fs.realpathSync(root); } catch { real = path.resolve(root); }
    if (isInside(real, realApprovals) || isInside(realApprovals, real)) return { ok: false, reason: "approvalDir overlaps the round/output/evidence directories and is not trusted" };
  }
  const trustedFile = path.join(realApprovals, `${candidateId}.expectation-review.json`);
  const preservedFile = path.join(caseDir, "workdir", "expectation-review.json");
  let trustedBytes;
  let preservedBytes;
  try {
    const st = fs.lstatSync(trustedFile);
    if (!st.isFile() || st.size > MAX_REVIEW_BYTES) return { ok: false, reason: "trusted review is not a regular file within the size bound" };
    trustedBytes = fs.readFileSync(trustedFile);
  } catch {
    return { ok: false, reason: `no operator review for candidate '${candidateId}' exists in the trusted approvalDir` };
  }
  try {
    preservedBytes = fs.readFileSync(preservedFile);
  } catch {
    return { ok: false, reason: "the preserved evidence carries no expectation review" };
  }
  if (sha256(trustedBytes) !== sha256(preservedBytes)) return { ok: false, reason: "the preserved expectation review differs from the operator's original (rewritten or substituted)", trustedSha256: sha256(trustedBytes), preservedSha256: sha256(preservedBytes) };
  let parsed;
  try { parsed = JSON.parse(trustedBytes.toString("utf8")); } catch { return { ok: false, reason: "trusted review is not valid JSON" }; }
  if (parsed?.candidateId !== candidateId) return { ok: false, reason: "trusted review names a different candidate" };
  return { ok: true, sha256: sha256(trustedBytes) };
}

/**
 * grade.sh executes whatever case file and workdir the (unsigned, hash-only) manifest points at. Only this workflow's
 * generated layout is accepted: case_file.path === "case.yaml" and evidence.workdir.path === "workdir", both plain
 * entries (no symlink) whose canonical location is directly inside the canonical case directory. Because these are the
 * exact files inspectCaseDefinition reads and the review comparison uses, a rewritten manifest cannot redirect grading
 * to an alternate (e.g. shell-bearing) case file or an alternate evidence tree.
 */
export function inspectManifestBindings(caseDir, manifestFile) {
  let manifest;
  try {
    const st = fs.lstatSync(manifestFile);
    if (!st.isFile()) return { ok: false, reason: "grading manifest is not a regular file" };
    manifest = JSON.parse(fs.readFileSync(manifestFile, "utf8"));
  } catch {
    return { ok: false, reason: "grading manifest is unreadable or not JSON" };
  }
  if (manifest?.case_file?.path !== "case.yaml") return { ok: false, reason: `manifest case_file.path '${manifest?.case_file?.path}' is not the generated 'case.yaml'` };
  if (manifest?.evidence?.workdir?.path !== "workdir") return { ok: false, reason: `manifest evidence.workdir.path '${manifest?.evidence?.workdir?.path}' is not the generated 'workdir'` };
  let realCase;
  try {
    realCase = fs.realpathSync(caseDir);
  } catch {
    return { ok: false, reason: "case directory is not readable" };
  }
  for (const [name, kind] of [["case.yaml", "file"], ["workdir", "directory"]]) {
    const entry = path.join(caseDir, name);
    let st;
    try {
      st = fs.lstatSync(entry);
    } catch {
      return { ok: false, reason: `${name} is missing from the preserved case` };
    }
    if (st.isSymbolicLink()) return { ok: false, reason: `${name} is a symbolic link` };
    if (kind === "file" ? !st.isFile() : !st.isDirectory()) return { ok: false, reason: `${name} is not a regular ${kind}` };
    if (fs.realpathSync(entry) !== path.join(realCase, name)) return { ok: false, reason: `${name} does not resolve directly inside the case directory` };
  }
  if (manifest.mode !== undefined && manifest.mode !== "deterministic") return { ok: false, reason: "manifest mode is not deterministic" };
  return { ok: true };
}

/** Replays one preserved case through grade.sh. Never throws; failure means "not independently verified". */
export function recomputeCase({ caseDir, gradeSh = DEFAULT_GRADE_SH, env = process.env, timeoutMs = 300000 }) {
  const manifest = path.join(caseDir, "grading-manifest.json");
  if (!fs.existsSync(manifest)) return { recomputed: false, reason: "preserved grading manifest is missing" };
  const bindings = inspectManifestBindings(caseDir, manifest);
  if (!bindings.ok) return { recomputed: false, reason: `preserved grading manifest refused before grading: ${bindings.reason}` };
  const definition = inspectCaseDefinition(caseDir);
  if (!definition.ok) return { recomputed: false, reason: `preserved case definition refused before grading: ${definition.reason}` };
  const run = spawnSync("bash", [gradeSh, `--manifest=${manifest}`], { env, encoding: "utf8", timeout: timeoutMs, maxBuffer: MAX_GRADE_OUTPUT });
  if (run.error) return { recomputed: false, reason: `grade.sh could not run: ${run.error.message}` };
  // grade.sh prints one (pretty-printed) JSON document; tolerate stray leading lines by trying each line start.
  const text = run.stdout ?? "";
  let doc = null;
  const starts = [0, ...[...text.matchAll(/\n(?=\{)/g)].map(m => m.index + 1)];
  for (const start of starts) {
    try {
      doc = JSON.parse(text.slice(start).trim());
      break;
    } catch {
      doc = null;
    }
  }
  if (run.status !== 0 || !doc || doc.status === "ERROR") {
    const reason = doc?.diff_hint ?? doc?.actual ?? `grade.sh exited ${run.status}`;
    return { recomputed: false, reason: `independent grading failed: ${String(reason).slice(0, 300)}`, exitCode: run.status };
  }
  return { recomputed: true, status: doc.status ?? null, discovery: doc.discovery ?? null, gradingManifest: doc.grading_manifest ?? null };
}

/** Whether results.json's claim equals what the replay recomputed (the claim is never trusted on its own). */
export function claimMatches(raw, recomputed) {
  if (raw === null && recomputed === null) return true;
  if (raw === null || recomputed === null) return false;
  const pick = f => [f.classification, f.matrix, f.candidateId, f.reproducible, f.requirementSupported, f.evidenceStatus, f.attestation?.trust ?? null, f.attestation?.sha256 ?? null];
  return JSON.stringify(pick(raw)) === JSON.stringify(pick(recomputed));
}

/** VERIFIED_REGRESSION backed by recomputed valid evidence, stability, spec support and an independent signer. */
export function isIndependentVerified(entry) {
  const d = entry.finding;
  return Boolean(entry.recomputed && entry.consistent && d
    && d.classification === "VERIFIED_REGRESSION" && d.evidenceStatus === "valid" && d.finalized !== false
    && d.reproducible === true && d.requirementSupported === true && INDEPENDENT_TRUST.has(d.attestation?.trust)
    && entry.trustedReview?.ok === true);
}

/**
 * Replays every case that reports a finding or a non-PASS status. `evidenceRoot/<caseId>/` must be the preserved
 * run-dir case directory (grading-manifest.json at its root). `approvalDir` is the caller's TRUSTED operator review
 * directory; `untrustedRoots` are the round/output/evidence directories it must stay outside of.
 * Returns one entry per replayed case.
 */
export function recomputeRound({ results, evidenceRoot, gradeSh = DEFAULT_GRADE_SH, stateDir, env = process.env, approvalDir = null, untrustedRoots = [] }) {
  const childEnv = { ...env };
  if (stateDir) childEnv.EVAL_STATE_DIR = stateDir;
  const roots = [evidenceRoot, ...untrustedRoots];
  const entries = [];
  for (const c of results?.cases ?? []) {
    const rawFinding = c.discovery && typeof c.discovery === "object" ? c.discovery : null;
    if (!rawFinding && c.status === "PASS") continue;
    const caseId = c.case_id ?? c.caseId;
    const base = { caseId, rawStatus: c.status ?? null, rawClassification: rawFinding?.classification ?? null, rawTrust: rawFinding?.attestation?.trust ?? null };
    if (typeof caseId !== "string" || !SAFE_ID.test(caseId)) {
      entries.push({ ...base, recomputed: false, consistent: false, reason: "case id is not a safe path segment", finding: null, independent: false });
      continue;
    }
    const caseDir = path.join(evidenceRoot, caseId);
    const outcome = recomputeCase({ caseDir, gradeSh, env: childEnv });
    if (!outcome.recomputed) {
      entries.push({ ...base, recomputed: false, consistent: false, reason: outcome.reason, finding: null, independent: false });
      continue;
    }
    const consistent = claimMatches(rawFinding, outcome.discovery);
    const entry = {
      ...base, recomputed: true, gradeStatus: outcome.status, classification: outcome.discovery?.classification ?? null,
      trust: outcome.discovery?.attestation?.trust ?? null, consistent,
      reason: consistent ? null : "results.json disagrees with the recomputed grading of the preserved evidence (possible tampering or stale results)",
      finding: outcome.discovery,
    };
    const verifiedByIndependentSigner = consistent && outcome.discovery?.classification === "VERIFIED_REGRESSION" && INDEPENDENT_TRUST.has(entry.trust);
    if (verifiedByIndependentSigner) {
      entry.trustedReview = checkTrustedReview({ caseDir, candidateId: outcome.discovery.candidateId, approvalDir, untrustedRoots: roots });
      if (!entry.trustedReview.ok) entry.independentBlockedReason = entry.trustedReview.reason;
    }
    entry.independent = isIndependentVerified(entry);
    entries.push(entry);
  }
  return entries;
}
