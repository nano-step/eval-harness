#!/usr/bin/env bash
# scripts/eval/discovery/ci-evidence.sh — independent-signer CI acceptance run over the FROZEN discovery dataset.
#
#   ci-evidence.sh --out=<new absolute dir> --dependencies=<trusted snapshot dir> --state-dir=<absolute state dir>
#
# What it does (existing pipeline only; no model call, no new evaluation framework):
#   1. verifies every file of examples/discovery-pilot/frozen against its recorded sha256, builds the collision fixture with
#      the existing builder and requires the full commit SHAs, SPEC.md and lockfile to equal the frozen context (it never
#      retargets a dataset to different revisions);
#   2. copies the frozen rounds under <out>/{clean,defect} and re-evaluates them with the existing `run.mjs --reevaluate`
#      (fresh sandbox executions, fresh signatures, transport "reuse", 0 generation calls) using the operator's original
#      reviews from the repository as the TRUSTED --approval-dir;
#   3. runs real StrykerJS inside the sandbox for the baseline and with the fresh PASS guided tests;
#   4. drives the actual jev-gate.sh (--mode=block, bounded to 1 request / 1 attempt) over the frozen defect round and asks
#      repair-request.mjs for the same preserved result again to show an idempotent ledger and no stale relabel;
#   5. writes <out>/ci-observations.json: compact observations read from the existing results, mutation and repair outputs
#      plus the checks this helper asserts. It is an observation record, not a new status authority.
#
# Signer trust comes ONLY from the environment this script is given; it never creates, labels or reads key material:
#   independent  ATD_TRUST=ci-secret|separate-user with absolute ATD_SIGNING_KEY_FILE and ATD_ALLOWED_SIGNERS_FILE supplied by
#                the CI job (key outside the checkout, <out> and <state-dir>). Expected: gate exit 14 and a repair request.
#   local        otherwise (local-same-user). Honest advisory mode: expected gate exit 0, no repair request; it does NOT claim
#                independence. Only a remote CI run with an external key is authoritative.
# The private key is never uploaded or printed. The public allowed_signers file and its fingerprint are copied to <out>/public.
#
# Exit codes: 0 every check passed, 1 at least one check failed (all outputs preserved), 2 usage/precondition failure.

set -euo pipefail
set +x

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_ROOT="$(cd "$SELF_DIR/../../.." && pwd -P)"
FIXTURE_SRC="$HARNESS_ROOT/examples/discovery-pilot/collision"
FROZEN="$HARNESS_ROOT/examples/discovery-pilot/frozen"
RUN_MJS="$SELF_DIR/run.mjs"
GATE_SH="$SELF_DIR/jev-gate.sh"
REPAIR_MJS="$SELF_DIR/repair-request.mjs"
POLICY="$SELF_DIR/policy/atd-sandbox.v1.json"

die() { echo "[ci-evidence] $*" >&2; exit 2; }
info() { echo "[ci-evidence] $*" >&2; }

OUT="" DEPS="" STATE=""
for arg in "$@"; do
  case "$arg" in
    --out=*)          OUT="${arg#*=}" ;;
    --dependencies=*) DEPS="${arg#*=}" ;;
    --state-dir=*)    STATE="${arg#*=}" ;;
    -h|--help)        sed -n '2,31p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "unknown argument: $arg" ;;
  esac
done
[[ -n "$OUT" && -n "$DEPS" && -n "$STATE" ]] || die "--out, --dependencies and --state-dir are required"
for p in "$OUT" "$DEPS" "$STATE"; do [[ "$p" == /* && "$p" != *","* ]] || die "paths must be absolute and must not contain commas: $p"; done
for tool in node jq git docker python3 ssh-keygen; do command -v "$tool" >/dev/null 2>&1 || die "$tool is required"; done
command -v yq >/dev/null 2>&1 || python3 -c 'import yaml' >/dev/null 2>&1 || die "yq or python3 with pyyaml is required"

realpath_loose() { python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1"; }
inside() { case "$(realpath_loose "$2")/" in "$(realpath_loose "$1")/"*) return 0 ;; *) return 1 ;; esac; }
sha256_file() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }

# --- validate everything before the first write -----------------------------------------------------------------------
[[ ! -e "$OUT" ]] || die "--out already exists (evidence is never overwritten): $OUT"
[[ -d "$(dirname "$OUT")" ]] || die "parent of --out does not exist: $(dirname "$OUT")"
if [[ -e "$STATE" ]]; then
  [[ -d "$STATE" && -z "$(ls -A "$STATE")" ]] || die "--state-dir must not exist yet or be an empty directory: $STATE"
fi
inside "$HARNESS_ROOT" "$OUT" && die "--out must be outside the repository checkout (the trusted reviews live there)"
inside "$HARNESS_ROOT" "$STATE" && die "--state-dir must be outside the repository checkout"
inside "$OUT" "$STATE" && die "--state-dir must not be inside --out"
inside "$STATE" "$OUT" && die "--out must not be inside --state-dir"
inside "$OUT" "$DEPS" && die "--dependencies must be outside --out"
[[ -d "$DEPS/node_modules" && -f "$DEPS/package-lock.json" ]] || die "--dependencies must contain node_modules/ and package-lock.json (build it with setup-deps.sh)"
LOCK_SHA="$(sha256_file "$FIXTURE_SRC/package-lock.json")"
[[ "$(sha256_file "$DEPS/package-lock.json")" == "$LOCK_SHA" ]] || die "dependency snapshot lockfile differs from the fixture lockfile"
SPEC_SHA="$(sha256_file "$FIXTURE_SRC/SPEC.md")"

# trust mode comes from the supplied environment only
TRUST="${ATD_TRUST:-local-same-user}"
case "$TRUST" in
  ci-secret|separate-user)
    [[ -n "${ATD_SIGNING_KEY_FILE:-}" && -n "${ATD_ALLOWED_SIGNERS_FILE:-}" ]] || die "ATD_TRUST=$TRUST needs ATD_SIGNING_KEY_FILE and ATD_ALLOWED_SIGNERS_FILE from the trusted CI environment"
    for f in "$ATD_SIGNING_KEY_FILE" "$ATD_ALLOWED_SIGNERS_FILE"; do [[ "$f" == /* && -f "$f" ]] || die "signer files must be absolute regular files"; done
    for root in "$HARNESS_ROOT" "$OUT" "$STATE"; do
      inside "$root" "$ATD_SIGNING_KEY_FILE" && die "the signing key must live outside the checkout, --out and --state-dir"
      inside "$root" "$ATD_ALLOWED_SIGNERS_FILE" && die "allowed_signers must live outside the checkout, --out and --state-dir"
    done
    MODE=independent ;;
  local-same-user) MODE=local ;;
  *) die "ATD_TRUST must be ci-secret, separate-user or local-same-user" ;;
esac

docker version --format '{{.Server.Version}}' >/dev/null 2>&1 || die "docker daemon is not reachable (the sandbox fails closed; there is no host fallback)"
IMAGE="$(jq -r '.image.ref' "$POLICY")"
docker image inspect "$IMAGE" >/dev/null 2>&1 || die "pinned sandbox image $IMAGE is not present locally (it is never pulled by the runner)"

# the frozen dataset must be byte-identical to what dataset.json records
[[ -f "$FROZEN/dataset.json" ]] || die "frozen dataset missing: $FROZEN"
[[ -z "$(find "$FROZEN" -type l)" ]] || die "the frozen dataset must not contain symlinks"
FROZEN_COUNT=0
while IFS=$'\t' read -r rel want; do
  [[ -f "$FROZEN/$rel" ]] || die "frozen file missing: $rel"
  [[ "$(sha256_file "$FROZEN/$rel")" == "$want" ]] || die "frozen file changed: $rel"
  FROZEN_COUNT=$((FROZEN_COUNT + 1))
done < <(jq -r '.files | to_entries[] | [.key, .value] | @tsv' "$FROZEN/dataset.json")
[[ "$(find "$FROZEN" -type f ! -name dataset.json | wc -l | tr -d ' ')" == "$FROZEN_COUNT" ]] || die "the frozen dataset contains files that dataset.json does not record"
[[ "$(jq -r '.context.specSha256' "$FROZEN/dataset.json")" == "$SPEC_SHA" && "$(jq -r '.context.lockfileSha256' "$FROZEN/dataset.json")" == "$LOCK_SHA" ]] || die "the frozen dataset was produced for a different SPEC.md or lockfile; it is never retargeted"

# --- writes start here ------------------------------------------------------------------------------------------------
mkdir -p "$OUT/fixture" "$OUT/steps" "$OUT/clean" "$OUT/defect"
OUT="$(cd "$OUT" && pwd -P)"
: > "$OUT/steps.log"
fail_early() { echo "[ci-evidence] $*" >&2; exit 2; }

bash "$FIXTURE_SRC/build-fixture-repo.sh" "$OUT/fixture/repo" > "$OUT/fixture/fixture.raw.json"
REPO="$(jq -r .repository "$OUT/fixture/fixture.raw.json")"
BASE="$(jq -r .baseCommit "$OUT/fixture/fixture.raw.json")"
CLEAN="$(jq -r .revisions.clean.commit "$OUT/fixture/fixture.raw.json")"
BOUNDARY="$(jq -r .revisions.boundaryDefect.commit "$OUT/fixture/fixture.raw.json")"
[[ "$BASE" == "$(jq -r .context.baseCommit "$FROZEN/dataset.json")" && "$CLEAN" == "$(jq -r .context.cleanCommit "$FROZEN/dataset.json")" && "$BOUNDARY" == "$(jq -r .context.boundaryDefectCommit "$FROZEN/dataset.json")" ]] \
  || fail_early "the rebuilt fixture commits differ from the frozen context (base $BASE clean $CLEAN defect $BOUNDARY); the frozen dataset is never retargeted"
[[ "$(sha256_file "$REPO/SPEC.md")" == "$SPEC_SHA" ]] || fail_early "the rebuilt fixture SPEC.md differs from the frozen context"
jq --arg node "$(node --version)" --arg docker "$(docker version --format '{{.Server.Version}}')" --arg git "$(git --version)" --arg image "$IMAGE" --arg lock "$LOCK_SHA" --arg at "$(date -u +%FT%TZ)" --arg mode "$MODE" \
   '. + {environment:{hostNode:$node,docker:$docker,git:$git,sandboxImage:$image,lockfileSha256:$lock,startedAt:$at,mode:$mode}}' "$OUT/fixture/fixture.raw.json" > "$OUT/fixture/fixture.json"
rm -f "$OUT/fixture/fixture.raw.json"

# public signer data only (never the private key)
FINGERPRINT=""
if [[ "$MODE" == independent ]]; then
  mkdir -p "$OUT/public"
  cp "$ATD_ALLOWED_SIGNERS_FILE" "$OUT/public/allowed_signers"
  awk 'NF >= 3 { for (i = 1; i < NF; i++) if ($i ~ /^(ssh-|ecdsa-|sk-)/) { print $i, $(i + 1); exit } }' "$OUT/public/allowed_signers" > "$OUT/public/signer.pub"
  FINGERPRINT="$(ssh-keygen -lf "$OUT/public/signer.pub" 2>/dev/null | awk '{print $2}')"
  printf '%s\n' "$FINGERPRINT" > "$OUT/public/signer.fingerprint"
fi
info "mode: $MODE (trust=$TRUST)$([[ "$MODE" == local ]] && echo ' — advisory only; this is NOT independent-signer evidence')"

step() {
  local label="$1"; shift
  info "step: $label"
  set +e
  "$@" 2>&1 | tee "$OUT/steps/$label.log" >&2
  STEP_RC="${PIPESTATUS[0]}"
  set -e
  echo "$STEP_RC" > "$OUT/steps/$label.exit"
  echo "$label exit=$STEP_RC" >> "$OUT/steps.log"
  return 0
}
summary_of() { sed -n 's/^ATD_SUMMARY=//p' "$OUT/steps/$1.log" | tail -n 1; }

node "$RUN_MJS" pilot-snapshot "--out=$OUT" --name=before >/dev/null

cp -R "$FROZEN/clean/round-001" "$OUT/clean/round-001"
cp -R "$FROZEN/clean/round-002" "$OUT/clean/round-002"
cp -R "$FROZEN/defect/round-001" "$OUT/defect/round-001"

COMMON=("--repo=$REPO" "--spec=$REPO/SPEC.md" "--dependencies=$DEPS" "--state-dir=$STATE" "--framework=vitest")

# 1. clean change, frozen proposals, fresh executions (0 generation calls)
step clean-original node "$RUN_MJS" run "${COMMON[@]}" "--base=$BASE" "--candidate=$CLEAN" "--out=$OUT/clean" "--reevaluate=$OUT/clean/round-001"
CLEAN_ORIGINAL_SUMMARY="$(summary_of clean-original)"
step clean-guided node "$RUN_MJS" run "${COMMON[@]}" "--base=$BASE" "--candidate=$CLEAN" "--out=$OUT/clean" "--reevaluate=$OUT/clean/round-002" "--approval-dir=$FROZEN/operator-reviews/clean-guided"
GUIDED_SUMMARY="$(summary_of clean-guided)"
GUIDED_ROUND=""
[[ -z "$GUIDED_SUMMARY" ]] || GUIDED_ROUND="$(dirname "$GUIDED_SUMMARY")"

# 2. real Stryker inside the sandbox: baseline, then with the fresh PASS guided tests (same plan and config)
if [[ -n "$GUIDED_ROUND" && -f "$GUIDED_ROUND/risk.json" ]]; then
  step mutation-baseline node "$RUN_MJS" mutation-evidence "--repo=$REPO" "--commit=$CLEAN" "--risk=$GUIDED_ROUND/risk.json" "--dependencies=$DEPS" "--state-dir=$STATE" "--out=$OUT/mutation/baseline"
  step mutation-with-tests node "$RUN_MJS" mutation-evidence "--repo=$REPO" "--commit=$CLEAN" "--risk=$GUIDED_ROUND/risk.json" "--dependencies=$DEPS" "--state-dir=$STATE" "--round=$GUIDED_ROUND" "--baseline=$OUT/mutation/baseline" "--out=$OUT/mutation/with-generated-tests"
else
  info "no guided round risk report; mutation steps were skipped and will be reported as failed checks"
fi

# 3. actual Jev gate in block mode over the frozen defect round, bounded to one request and one attempt
step gate-defect bash "$GATE_SH" "--repo=$REPO" "--base=$BASE" "--candidate=$BOUNDARY" "--spec=$REPO/SPEC.md" "--dependencies=$DEPS" "--state-dir=$STATE" "--out=$OUT/defect" "--reevaluate=$OUT/defect/round-001" "--approval-dir=$FROZEN/operator-reviews/defect" --mode=block --max-requests=1 --max-attempts=1
GATE_RC="$STEP_RC"
GATE_ROUND=""
GATE_SUMMARY="$(sed -n 's/^round summary: //p' "$OUT/steps/gate-defect.log" | tail -n 1)"
[[ -z "$GATE_SUMMARY" ]] || GATE_ROUND="$(dirname "$GATE_SUMMARY")"

# 4. the same preserved result again: the ledger must hand back the same request (no new attempt, no relabel)
AGAIN_RC=-1
if [[ -n "$GATE_ROUND" && -f "$GATE_ROUND/results.json" ]]; then
  set +e
  node "$REPAIR_MJS" "--results=$GATE_ROUND/results.json" "--ledger-dir=$OUT/defect/repair" "--candidate-commit=$BOUNDARY" --max-attempts=1 --max-requests=1 \
    "--state-dir=$STATE" "--approval-dir=$FROZEN/operator-reviews/defect" > "$OUT/defect/repair-again.json" 2> "$OUT/steps/repair-again.log"
  AGAIN_RC=$?
  set -e
  echo "repair-again exit=$AGAIN_RC" >> "$OUT/steps.log"
fi

node "$RUN_MJS" pilot-snapshot "--out=$OUT" --name=after >/dev/null

GUARD_LINE="$(git -C "$REPO" show "$CLEAN:src/collision.ts" | grep -n 'b.width === 0' | head -n 1 | cut -d: -f1 || true)"

# --- observations (read from existing outputs; checks are this helper's assertions) -----------------------------------------
set +e
OBS_OUT="$OUT" OBS_STATE="$STATE" OBS_REPORT_MODULE="$HARNESS_ROOT/scripts/eval/discovery/workflow-report.mjs" OBS_MODE="$MODE" OBS_TRUST="$TRUST" OBS_FINGERPRINT="$FINGERPRINT" OBS_DATASET="$FROZEN/dataset.json" OBS_GATE_RC="$GATE_RC" OBS_AGAIN_RC="$AGAIN_RC" \
OBS_GUARD_LINE="$GUARD_LINE" OBS_CLEAN_ORIGINAL="${CLEAN_ORIGINAL_SUMMARY:+$(dirname "$CLEAN_ORIGINAL_SUMMARY")}" OBS_GUIDED="$GUIDED_ROUND" OBS_GATE_ROUND="$GATE_ROUND" \
OBS_CLEAN="$CLEAN" OBS_BASE="$BASE" OBS_BOUNDARY="$BOUNDARY" OBS_REPO="$REPO" OBS_FROZEN="$FROZEN" \
node --input-type=module - <<'JS'
import crypto from "node:crypto";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

const E = process.env;
const OUT = E.OBS_OUT;
const rj = file => { try { return JSON.parse(fs.readFileSync(file, "utf8")); } catch { return null; } };
const filled = file => { try { return fs.statSync(file).size > 0; } catch { return false; } };
const sha = file => crypto.createHash("sha256").update(fs.readFileSync(file)).digest("hex");
const rel = file => (file ? path.relative(OUT, file) : null);
const checks = [];
const check = (id, pass, detail) => checks.push({ id, pass: pass === true, detail: detail ?? null });
const dataset = rj(E.OBS_DATASET);
const independent = E.OBS_MODE === "independent";
const REGRESSION = new Set(["VERIFIED_REGRESSION", "SUSPECTED_REGRESSION"]);

function round(label, dir, expectedSelected) {
  const summary = dir ? rj(path.join(dir, "round-summary.json")) : null;
  const results = dir ? rj(path.join(dir, "results.json")) : null;
  const o = {
    label, dir: rel(dir), expectedSelected, status: summary?.status ?? null,
    transport: summary?.generation?.transport ?? null, freshModelCalls: summary?.generation?.modelCalls ?? null,
    original: summary?.generation?.originalProvenance ? { round: summary.generation.originalProvenance.round, modelCalls: summary.generation.originalProvenance.modelCalls, servedModels: summary.generation.originalProvenance.servedModels, promptSha256: summary.generation.originalProvenance.promptSha256, mutantsShownToModel: summary.generation.originalProvenance.mutantsShownToModel } : null,
    accepted: summary?.candidates?.accepted ?? null, rejected: (summary?.candidates?.rejected ?? []).length,
    harnessVerdict: results?.verdict ?? summary?.harness?.verdict ?? null, cases: (summary?.cases ?? []).map(c => ({ caseId: c.caseId, status: c.status, classification: c.classification })),
    classificationCounts: summary?.classificationCounts ?? null, recomputedClassificationCounts: summary?.recomputedClassificationCounts ?? null,
    nonPass: (summary?.nonPass ?? []).length, errors: (summary?.errors ?? []).map(e => `${e.stage}/${e.code}`),
    summarySha256: dir && filled(path.join(dir, "round-summary.json")) ? sha(path.join(dir, "round-summary.json")) : null,
    resultsSha256: dir && filled(path.join(dir, "results.json")) ? sha(path.join(dir, "results.json")) : null,
    artifacts: Object.fromEntries(["results.json", "diff.md", "reports/discovery.junit.xml", "reports/discovery.sarif.json"].map(f => [f, dir ? filled(path.join(dir, f)) : false])),
  };
  return { o, summary, results };
}
const byLabel = {
  cleanOriginal: round("clean-original", E.OBS_CLEAN_ORIGINAL, dataset.rounds.find(r => r.scenario === "clean" && r.round === "round-001").selected.length),
  cleanGuided: round("clean-guided", E.OBS_GUIDED, dataset.rounds.find(r => r.scenario === "clean" && r.round === "round-002").selected.length),
  defect: round("defect-gate", E.OBS_GATE_ROUND, dataset.rounds.find(r => r.scenario === "defect").selected.length),
};
const all = Object.values(byLabel);

// replay provenance: transport reuse, 0 fresh generation calls, original Sonnet generation preserved, current validation re-accepts the selection
check("fresh_generation_calls_zero", all.every(r => r.o.transport === "reuse" && r.o.freshModelCalls === 0), all.map(r => ({ round: r.o.label, transport: r.o.transport, calls: r.o.freshModelCalls })));
check("original_sonnet_provenance_preserved", all.every(r => r.o.original?.modelCalls === 1 && (r.o.original.servedModels ?? []).includes("anthropic/claude-sonnet-5-5")), all.map(r => r.o.original));
check("guided_proposal_context_preserved", (byLabel.cleanGuided.o.original?.mutantsShownToModel ?? 0) > 0, byLabel.cleanGuided.o.original?.mutantsShownToModel ?? null);
check("selection_revalidated", all.every(r => r.o.accepted === r.o.expectedSelected && r.o.rejected === 0), all.map(r => ({ round: r.o.label, accepted: r.o.accepted, expected: r.o.expectedSelected, rejected: r.o.rejected })));

// clean change: no regression finding, every fresh case PASS
for (const r of [byLabel.cleanOriginal, byLabel.cleanGuided]) {
  const cc = Object.keys(r.o.classificationCounts ?? {});
  check(`${r.o.label}_no_regression_findings`, r.o.status === "completed" && r.o.cases.length === r.o.expectedSelected && r.o.cases.every(c => c.status === "PASS") && r.o.nonPass === 0
    && cc.every(k => !REGRESSION.has(k) && k !== "INCONCLUSIVE") && (r.summary?.verifiedIndependentFindingIds ?? []).length === 0, { status: r.o.status, cases: r.o.cases.length, classes: r.o.classificationCounts, harnessVerdict: r.o.harnessVerdict });
}

// real defect: verified from fresh signed samples, trust exactly as supplied by the environment
const verified = (byLabel.defect.summary?.recomputedFindings ?? []).filter(f => f.classification === "VERIFIED_REGRESSION");
const stable = verified.filter(f => f.evidenceStatus === "valid" && f.reproducible === true && f.requirementSupported === true && f.stability?.state === "verified" && (f.stability?.observedSamples ?? 0) >= 3);
check("defect_verified_with_three_fresh_signed_samples", stable.length >= 1, { verified: verified.length, stableVerified: stable.length, findings: stable.slice(0, 5).map(f => ({ id: f.findingId, candidate: f.candidateId, trust: f.attestation?.trust, samples: f.stability?.observedSamples, executionIds: (f.stability?.executionIds ?? []).length })) });

// gate + bounded repair
const rec = E.OBS_GATE_ROUND ? rj(path.join(E.OBS_GATE_ROUND, "repair-recommendation.json")) : null;
const again = rj(path.join(OUT, "defect", "repair-again.json"));
const ledgerFile = path.join(OUT, "defect", "repair", "ledger.ndjson");
const ledger = fs.existsSync(ledgerFile) ? fs.readFileSync(ledgerFile, "utf8").split("\n").filter(Boolean).map(l => JSON.parse(l)) : [];
const requestFiles = fs.existsSync(path.join(OUT, "defect", "repair")) ? fs.readdirSync(path.join(OUT, "defect", "repair")).filter(n => /^repair-.*\.json$/.test(n)) : [];
const gateRc = Number(E.OBS_GATE_RC);
const trustSeen = [...new Set(verified.map(f => f.attestation?.trust))];
if (independent) {
  check("gate_blocks_on_independent_verified_regression", gateRc === 14 && (rec?.independentVerified ?? []).length >= 1, { exit: gateRc, independentVerified: (rec?.independentVerified ?? []).length });
  check("signer_trust_is_the_supplied_independent_label", trustSeen.length >= 1 && trustSeen.every(t => t === E.OBS_TRUST), { expected: E.OBS_TRUST, seen: trustSeen });
  check("repair_request_bounded", (rec?.requests ?? []).length === 1 && requestFiles.length === 1 && ledger.filter(l => l.status === "issued").length === 1 && ledger.every(l => l.attempt === undefined || l.attempt === 1), { requests: (rec?.requests ?? []).length, requestFiles: requestFiles.length, ledger: ledger.map(l => ({ status: l.status, attempt: l.attempt ?? null })) });
  check("repair_request_idempotent_no_stale_relabel", Number(E.OBS_AGAIN_RC) === 0 && (again?.requests ?? []).length === 1 && again.requests[0].reused === true && again.requests[0].path === rec?.requests?.[0]?.path && again.requests[0].request?.candidateCommit === E.OBS_BOUNDARY
    && requestFiles.length === 1 && ledger.length === 1, { exit: Number(E.OBS_AGAIN_RC), reused: again?.requests?.[0]?.reused ?? null, samePath: again?.requests?.[0]?.path === rec?.requests?.[0]?.path, attestedCommit: again?.requests?.[0]?.request?.candidateCommit ?? null });
} else {
  check("local_mode_is_advisory_not_independent", gateRc === 0 && (rec?.independentVerified ?? []).length === 0 && (rec?.requests ?? []).length === 0 && (rec?.advisories ?? []).length >= 1 && trustSeen.every(t => t === "local-same-user"), { exit: gateRc, independentVerified: (rec?.independentVerified ?? []).length, requests: (rec?.requests ?? []).length, advisories: (rec?.advisories ?? []).length, trust: trustSeen });
}

// mutation: real Stryker in the sandbox; the two zero-size-second-rectangle guard mutants are real contract gaps
const signedPilot = (await import(pathToFileURL(E.OBS_REPORT_MODULE).href)).pilotReport({ out: OUT, stateDir: E.OBS_STATE }).report;
const mb = signedPilot.scenarios.mutation.baseline;
const signedWith = signedPilot.scenarios.mutation.withGeneratedTests;
// The sidecar supplies candidate labels only; each claimed file is independently bound to the signed tests tree.
const metadata = rj(path.join(OUT, "mutation", "with-generated-tests", "evidence.json"));
const testRoot = path.join(OUT, "mutation", "with-generated-tests", "accepted-tests");
const acceptedTests = (metadata?.acceptedTests ?? []).filter(t => {
  if (typeof t.testFile !== "string" || t.testFile.startsWith("/") || t.testFile.split("/").some(s => !s || s === "." || s === "..")) return false;
  try { return sha(path.join(testRoot, t.testFile)) === t.testSha256; } catch { return false; }
});
const mw = signedWith?.status === "measured" ? { ...signedWith, acceptedTests, skippedTests: metadata?.skippedTests ?? [] } : signedWith;
check("mutation_baseline_measured_with_survivor", mb?.status === "measured" && ((mb.counts?.survived ?? 0) + (mb.counts?.noCoverage ?? 0)) >= 1, mb ? { counts: mb.counts, score: mb.score } : null);
const guardLine = Number(E.OBS_GUARD_LINE);
const killedOnGuard = (mw?.comparison?.transitions ?? []).filter(t => t.line === guardLine);
check("guard_gap_mutants_killed_by_fresh_guided_tests", mw?.status === "measured" && guardLine > 0 && killedOnGuard.length >= 2, { guardLine: guardLine || null, killedOnGuard: killedOnGuard.map(t => ({ line: t.line, mutator: t.mutator, replacement: t.replacement })), killedTotal: mw?.comparison?.killedAfterSurvivalBefore ?? null, survivedBefore: mw?.comparison?.survivedBefore ?? null });
check("mutation_run_used_fresh_pass_tests_only", mw?.acceptedTests?.length === byLabel.cleanGuided.o.expectedSelected && (mw?.skippedTests ?? []).length === 0, { overlaid: (mw?.acceptedTests ?? []).map(t => t.testFile), skipped: mw?.skippedTests ?? null });

// The eight required behaviors. Test NAMES are only an index (they never prove semantics): a behavior counts as covered only
// when a matching test was executed by Stryker AND its body is bound to reviewed bytes: the checked-in baseline test blob at the
// mutation commit, or a generated test whose bytes equal the frozen dataset's and carry the operator's PASS review for exactly
// those bytes, with the fresh harness case for it PASSing on the clean revision.
const reportFile = path.join(OUT, "mutation", "with-generated-tests", "sandbox", "artifacts", "mutant.mutation-report.json");
const report = mw?.reportSha256 && filled(reportFile) && sha(reportFile) === mw.reportSha256 ? rj(reportFile) : null;
const testNames = Object.entries(report?.testFiles ?? {}).flatMap(([file, v]) => (v.tests ?? []).map(t => ({ file, name: String(t.name) })));
const guidedCases = new Map((byLabel.cleanGuided.o.cases ?? []).map(c => [c.caseId, c.status]));
const generatedByFile = new Map((mw?.acceptedTests ?? []).map(t => [t.testFile, t]));
const bind = file => {
  const generated = generatedByFile.get(file);
  if (!generated) {
    try {
      const blob = execFileSync("git", ["-C", E.OBS_REPO, "show", `${E.OBS_CLEAN}:${file}`], { maxBuffer: 1 << 22 });
      return { origin: "baseline (checked in at the mutation commit)", bound: true, testSha256: crypto.createHash("sha256").update(blob).digest("hex"), executedPass: true };
    } catch { return { origin: "unknown", bound: false, testSha256: null, executedPass: false }; }
  }
  const datasetRel = `clean/round-002/candidates/${generated.candidateId}/tests/${file}`;
  const review = rj(path.join(E.OBS_FROZEN, "operator-reviews", "clean-guided", `${generated.candidateId}.expectation-review.json`));
  const reviewFile = path.join(E.OBS_FROZEN, "operator-reviews", "clean-guided", `${generated.candidateId}.expectation-review.json`);
  const bound = dataset.files[datasetRel] === generated.testSha256 && review?.verdict === "PASS" && review?.testSha256 === generated.testSha256;
  return { origin: "frozen generated test with operator PASS review", bound, testSha256: generated.testSha256, reviewSha256: bound ? sha(reviewFile) : null, executedPass: guidedCases.get(generated.candidateId) === "PASS" };
};
const bindings = new Map([...new Set(testNames.map(t => t.file))].map(f => [f, bind(f)]));
const BEHAVIORS = [
  ["two_rectangles_overlap", /interiors intersect|penetration|contains|identical/i],
  ["touching_edges_do_not_overlap", /touching|edge touching|corner/i],
  ["separated_rectangles", /separated|gap on either axis|clear of/i],
  ["overlap_is_symmetric", /symmetric/i],
  ["translation_invariance", /translat(ing|ion)/i],
  ["zero_size_rectangles", /zero[- ]?size|zero width|zero height/i],
  ["negative_coordinates", /negative/i],
  ["movement_collision_boundary", /flush|moved rectangle|collides|translate keeps/i],
];
const behaviors = BEHAVIORS.map(([id, re]) => ({
  id,
  tests: testNames.filter(t => re.test(t.name)).map(t => ({ file: t.file, name: t.name, ...bindings.get(t.file) })),
}));
for (const b of behaviors) b.covered = b.tests.some(t => t.bound && t.executedPass);
check("eight_required_behaviors_covered", testNames.length > 0 && behaviors.every(b => b.covered), { testsObserved: testNames.length, uncovered: behaviors.filter(b => !b.covered).map(b => b.id), note: "names index hash-bound, reviewed test bodies executed by Stryker; names do not prove semantics" });

// source preserved and artifacts reachable through the existing reports
const before = rj(path.join(OUT, "integrity-before.json"));
const after = rj(path.join(OUT, "integrity-after.json"));
const sameSources = before && after && JSON.stringify([before.commits, before.refs, before.head, before.checkedOutFiles]) === JSON.stringify([after.commits, after.refs, after.head, after.checkedOutFiles]) && after.statusPorcelain === "";
check("source_repository_unchanged", sameSources === true, { workingTreeClean: after ? after.statusPorcelain === "" : null });
check("artifacts_accessible_through_existing_reports", all.every(r => Object.values(r.o.artifacts).every(Boolean)) && mb?.status === "measured" && mw?.status === "measured" && Boolean(report), all.map(r => ({ round: r.o.label, artifacts: r.o.artifacts })));
const privateMaterial = (() => {
  const hits = [];
  const walk = d => { for (const n of fs.readdirSync(d)) { const p = path.join(d, n); const st = fs.lstatSync(p); if (st.isSymbolicLink()) continue; if (st.isDirectory()) walk(p); else if (st.size < 1 << 20 && /-----BEGIN [A-Z ]*PRIVATE KEY-----/.test(fs.readFileSync(p, "utf8"))) hits.push(rel(p)); } };
  walk(OUT);
  return hits;
})();
check("no_private_key_material_in_output", privateMaterial.length === 0, privateMaterial);

const ci = E.GITHUB_RUN_ID ? {
  provider: "github-actions", repository: E.GITHUB_REPOSITORY ?? null, workflow: E.GITHUB_WORKFLOW ?? null, runId: E.GITHUB_RUN_ID, runAttempt: E.GITHUB_RUN_ATTEMPT ?? null,
  sha: E.GITHUB_SHA ?? null, ref: E.GITHUB_REF ?? null, runner: { os: E.RUNNER_OS ?? null, arch: E.RUNNER_ARCH ?? null },
  runUrl: E.GITHUB_SERVER_URL && E.GITHUB_REPOSITORY ? `${E.GITHUB_SERVER_URL}/${E.GITHUB_REPOSITORY}/actions/runs/${E.GITHUB_RUN_ID}` : null,
} : null;
const stepsExit = Object.fromEntries(fs.readdirSync(path.join(OUT, "steps")).filter(n => n.endsWith(".exit")).map(n => [n.replace(/\.exit$/, ""), Number(fs.readFileSync(path.join(OUT, "steps", n), "utf8"))]));
const observations = {
  schema: "atd.ci-observations/v1",
  note: "Observations read from existing results, mutation and repair outputs plus this helper's assertions. Not a status authority: verify the run through its CI provider and the signed evidence.",
  ci, mode: E.OBS_MODE, claimsIndependentSigner: independent,
  signer: { declaredTrust: E.OBS_TRUST, publicFingerprint: E.OBS_FINGERPRINT || null, allowedSignersSha256: independent && filled(path.join(OUT, "public", "allowed_signers")) ? sha(path.join(OUT, "public", "allowed_signers")) : null, publicFiles: independent ? ["public/allowed_signers", "public/signer.pub", "public/signer.fingerprint"] : [] },
  dataset: { sha256: sha(E.OBS_DATASET), source: dataset.source, context: dataset.context },
  commits: { base: E.OBS_BASE, clean: E.OBS_CLEAN, boundaryDefect: E.OBS_BOUNDARY },
  rounds: all.map(r => r.o),
  verifiedFindings: verified.map(f => ({ findingId: f.findingId, candidateId: f.candidateId, severity: f.severity, trust: f.attestation?.trust ?? null, attestationSha256: f.attestation?.sha256 ?? null, stability: { state: f.stability?.state, observedSamples: f.stability?.observedSamples, byteIdentical: f.stability?.byteIdentical } })),
  gate: { exitCode: gateRc, independentVerified: rec?.independentVerified ?? null, requests: (rec?.requests ?? []).map(r => ({ path: rel(r.path), attempt: r.request?.attempt, maxAttempts: r.request?.maxAttempts, candidateCommit: r.request?.candidateCommit })), advisories: (rec?.advisories ?? []).length, skipped: (rec?.skipped ?? []).map(s => s.reason).slice(0, 10), ledger },
  mutation: {
    baseline: mb ? { status: mb.status, counts: mb.counts, score: mb.score, executionRecord: mb.executionRecord ? { executionId: mb.executionRecord.executionId, outcome: mb.executionRecord.outcome } : null } : null,
    withGeneratedTests: mw ? { status: mw.status, counts: mw.counts, score: mw.score, comparison: mw.comparison ? { survivedBefore: mw.comparison.survivedBefore, killedAfterSurvivalBefore: mw.comparison.killedAfterSurvivalBefore, transitions: mw.comparison.transitions, stillSurviving: mw.comparison.normalizedComparison?.stillSurviving ?? null } : null } : null,
  },
  behaviors, steps: stepsExit, checks, failedChecks: checks.filter(c => !c.pass).map(c => c.id),
};
fs.writeFileSync(path.join(OUT, "ci-observations.json"), `${JSON.stringify(observations, null, 2)}\n`, { flag: "wx" });
const mark = c => (c.pass ? "PASS" : "FAIL");
process.stderr.write(`\n[ci-evidence] mode=${E.OBS_MODE} independentSigner=${independent} gateExit=${gateRc}\n${checks.map(c => `  ${mark(c)}  ${c.id}`).join("\n")}\n`);
process.exitCode = observations.failedChecks.length === 0 ? 0 : 1;
JS
OBS_RC=$?
set -e
echo "observations: $OUT/ci-observations.json"
exit "$OBS_RC"
