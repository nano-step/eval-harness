#!/usr/bin/env bash
# The per-run repair request cap bounds what an invocation hands out, whether a request is NEW or REUSED from the ledger.
# Uses the existing `gradeSh` seam of repair-request.mjs (a stand-in for the grade.sh replay) so the cap/ledger behaviour is
# observed without building signed sandbox evidence; the verification boundaries themselves are covered by the gate tests.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EH_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
for tool in node jq; do command -v "$tool" >/dev/null 2>&1 || { echo "SKIP: $tool required" >&2; exit 0; }; done
command -v yq >/dev/null 2>&1 || python3 -c 'import yaml' >/dev/null 2>&1 || { echo "SKIP: yq or pyyaml required" >&2; exit 0; }
WORK="$(mktemp -d -t atd-repair-cap.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
export WORK EH_ROOT

cat > "$WORK/fake-grade.sh" <<'EOF'
#!/usr/bin/env bash
# Replays a canned grade.sh answer stored beside the manifest.
cat "$(dirname "${1#--manifest=}")/fake-grade.json"
EOF
chmod +x "$WORK/fake-grade.sh"

node --input-type=module - <<'JS'
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";

const { buildRepairRequests } = await import(`${process.env.EH_ROOT}/scripts/eval/discovery/repair-request.mjs`);
const { WORK } = process.env;
const COMMIT = "c".repeat(40);
const hex = ch => ch.repeat(64);

function setup(name) {
  const root = path.join(WORK, name);
  const evidence = path.join(root, "evidence");
  const approvals = path.join(WORK, `${name}-approvals`);
  fs.mkdirSync(approvals, { recursive: true });
  const cases = [];
  for (const id of ["case-a", "case-b"]) {
    const dir = path.join(evidence, id);
    fs.mkdirSync(path.join(dir, "workdir"), { recursive: true });
    fs.writeFileSync(path.join(dir, "case.yaml"), `schema_version: 2\nid: ${id}\nrunner: atd-sandbox\nchecks:\n  - kind: discovery_finding\n    required: true\n    severity: high\n`);
    fs.writeFileSync(path.join(dir, "grading-manifest.json"), JSON.stringify({ case_file: { path: "case.yaml" }, evidence: { workdir: { path: "workdir" } } }));
    fs.writeFileSync(path.join(dir, "workdir", "candidate.json"), JSON.stringify({ requirementRef: { specSha256: hex("a"), quote: `requirement of ${id}` } }));
    const review = JSON.stringify({ schema_version: 1, verdict: "PASS", candidateId: id });
    fs.writeFileSync(path.join(dir, "workdir", "expectation-review.json"), review);
    fs.writeFileSync(path.join(approvals, `${id}.expectation-review.json`), review);
    const finding = { findingId: `F-${id}`, caseId: id, candidateId: id, classification: "VERIFIED_REGRESSION", matrix: "PASS->FAIL", reproducible: true, requirementSupported: true, evidenceStatus: "valid", finalized: true, severity: "high", targetFile: `src/${id}.ts`, candidateCommit: COMMIT, attestation: { trust: "separate-user", sha256: hex("b") } };
    fs.writeFileSync(path.join(dir, "fake-grade.json"), JSON.stringify({ status: "FAIL", discovery: finding }));
    cases.push({ case_id: id, status: "FAIL", discovery: finding });
  }
  const results = path.join(root, "results.json");
  fs.writeFileSync(results, JSON.stringify({ run_id: "run-1", cases }));
  return { results, evidence, approvals, ledger: path.join(WORK, `${name}-ledger`) };
}
const ask = (c, maxRequests, extra = {}) => buildRepairRequests({ resultsPath: c.results, evidenceRoot: c.evidence, ledgerDir: c.ledger, candidateCommit: COMMIT, maxAttempts: 3, maxRequests, gradeSh: path.join(WORK, "fake-grade.sh"), approvalDir: c.approvals, ...extra });
const ledgerRows = c => fs.readFileSync(path.join(c.ledger, "ledger.ndjson"), "utf8").split("\n").filter(Boolean).map(l => JSON.parse(l));

// 1. two independent verified regressions, cap 2: both issued, in the ledger
const c = setup("cap");
const first = ask(c, 2);
assert.equal(first.requests.length, 2, JSON.stringify(first.skipped));
assert.equal(ledgerRows(c).filter(r => r.status === "issued").length, 2);

// 2. the SAME ledger, cap lowered to 1: only one request may be handed out (previously both were returned as reused)
const again = ask(c, 1);
assert.equal(again.requests.length, 1, "a lowered cap must bound reused requests too");
assert.equal(again.requests[0].reused, true);
assert.ok(again.skipped.some(s => s.reason.includes("per-run request cap")), JSON.stringify(again.skipped));
assert.equal(ledgerRows(c).length, 2, "no new attempt or ledger row was created");

// 3. fresh ledger, cap 1: exactly one new request, one skipped by the cap, one ledger row
const fresh = setup("cap-fresh");
const one = ask(fresh, 1);
assert.equal(one.requests.length, 1);
assert.ok(one.skipped.some(s => s.reason.includes("per-run request cap")));
assert.equal(ledgerRows(fresh).filter(r => r.status === "issued").length, 1);
assert.equal(fs.readdirSync(fresh.ledger).filter(n => /^repair-.*\.json$/.test(n)).length, 1);

// 4. stale evidence for another commit neither issues nor spends an attempt
const stale = setup("cap-stale");
const staleRun = ask(stale, 2, { candidateCommit: "d".repeat(40) });
assert.equal(staleRun.requests.length, 0);
assert.equal(staleRun.skipped.filter(s => s.reason.startsWith("stale_evidence")).length, 2);
assert.ok(!fs.existsSync(path.join(stale.ledger, "ledger.ndjson")) || fs.readFileSync(path.join(stale.ledger, "ledger.ndjson"), "utf8") === "");

// 5. a corrupt ledger fails closed
const bad = setup("cap-corrupt");
fs.mkdirSync(bad.ledger, { recursive: true });
fs.writeFileSync(path.join(bad.ledger, "ledger.ndjson"), "this is not json\n");
assert.throws(() => ask(bad, 2), /ledger_corrupt/);
console.log("repair cap semantics ok");
JS

echo "PASS discovery_repair_cap"
