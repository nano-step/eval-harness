#!/usr/bin/env bash
# scripts/eval/discovery/jev-gate.sh — Jev test-command gate for Autonomous Test Discovery.
#
#   jev-gate.sh --base=<sha> --spec=<file> [--candidate=HEAD] [--mode=warn|block] [--repo=<dir>] [--out=<dir>]
#               [--dependencies=<snapshot>] [--state-dir=<dir>] [--framework=vitest|node:test]
#               [--max-attempts=3] [--max-requests=3] [--max-model-calls=1] [--max-candidates=12]
#               [--model=<provider/model[:thinking]>] [--approval-dir=<trusted dir>] [--seed=<n>]
#               [--eval-harness=<run.sh>]  (test seam)  [--transport=omp|fixture] [--fixture-response=<file>]
#               [--reevaluate=<earlier round dir under --out>]  (frozen replay: no model call)
#
# Use it as the Jev test command (Jev's existing test-command + maxRepairRounds hook; no Jev code change).
#
#   warn  (default): always exits 0. Every non-PASS status, error, and finding is preserved in the round
#                    artifacts and printed explicitly; the script never prints a success claim for a
#                    run that errored, was inconclusive, or produced nothing.
#   block (explicit opt-in): exits 14 only when at least one VERIFIED_REGRESSION is backed by valid
#                    evidence, a stability-bound reproduction, spec support AND an independent attestation
#                    (ci-secret or separate-user). A local-same-user attestation never blocks. A pipeline
#                    error exits 13 (the gate cannot certify). SUSPECTED / INCONCLUSIVE never fail.
#
# Repair requests come from repair-request.mjs for verified, independently attested regressions only, are
# bounded by --max-attempts per (target file, requirement) and distinct, and exhausted attempts surface as
# human review. Prior artifacts are never overwritten: each invocation writes a new round-NNN directory.

set -euo pipefail

GATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_MJS="$GATE_DIR/run.mjs"
REPAIR_MJS="$GATE_DIR/repair-request.mjs"

die() { echo "[atd-gate] $*" >&2; exit 2; }

command -v node >/dev/null 2>&1 || die "node is required"
command -v jq >/dev/null 2>&1 || die "jq is required"
command -v git >/dev/null 2>&1 || die "git is required"

MODE="warn"
BASE="" CANDIDATE="HEAD" SPEC="" REPO="" OUT="" APPROVAL_DIR=""
MAX_ATTEMPTS=3 MAX_REQUESTS=3
PASSTHRU=()

for arg in "$@"; do
  case "$arg" in
    --mode=*)         MODE="${arg#*=}" ;;
    --base=*)         BASE="${arg#*=}" ;;
    --candidate=*)    CANDIDATE="${arg#*=}" ;;
    --spec=*)         SPEC="${arg#*=}" ;;
    --repo=*)         REPO="${arg#*=}" ;;
    --out=*)          OUT="${arg#*=}" ;;
    --max-attempts=*) MAX_ATTEMPTS="${arg#*=}" ;;
    --max-requests=*) MAX_REQUESTS="${arg#*=}" ;;
    --approval-dir=*) APPROVAL_DIR="${arg#*=}"; PASSTHRU+=("$arg") ;;
    --dependencies=*|--state-dir=*|--framework=*|--max-model-calls=*|--max-candidates=*|--model=*|--require-model=*|--seed=*|--eval-harness=*|--transport=*|--fixture-response=*|--omp-bin=*|--image=*|--timeout-seconds=*|--generation-timeout=*|--skill=*|--stability-samples=*|--harness-timeout=*|--reevaluate=*)
                      PASSTHRU+=("$arg") ;;
    -h|--help)        sed -n '2,24p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "unknown argument: $arg" ;;
  esac
done

case "$MODE" in warn|block) ;; *) die "--mode must be warn or block" ;; esac
[[ -n "$BASE" ]] || die "--base=<sha> is required"
[[ -n "$SPEC" ]] || die "--spec=<file> is required"
[[ "$MAX_ATTEMPTS" =~ ^[1-9][0-9]?$ && "$MAX_REQUESTS" =~ ^[1-9][0-9]?$ ]] || die "--max-attempts/--max-requests must be small positive integers"
if [[ -z "$REPO" ]]; then REPO="$(git rev-parse --show-toplevel 2>/dev/null)" || die "not inside a git repository; pass --repo="; fi
REPO="$(cd "$REPO" && pwd -P)"
[[ -f "$SPEC" ]] || die "spec file not found: $SPEC"
SPEC="$(cd "$(dirname "$SPEC")" && pwd -P)/$(basename "$SPEC")"

CANDIDATE_SHA="$(git -C "$REPO" rev-parse --verify "${CANDIDATE}^{commit}" 2>/dev/null)" || die "cannot resolve --candidate=$CANDIDATE"
STATE_BASE="${EVAL_STATE_DIR:-$HOME/.config/opencode/eval-harness}"
if [[ -z "$OUT" ]]; then
  KEY="$(printf '%s' "$REPO" | cksum | cut -d' ' -f1)"
  OUT="$STATE_BASE/discovery/gate/$KEY"
fi
mkdir -p "$OUT"

RUN_ARGS=(run "--repo=$REPO" "--base=$BASE" "--candidate=$CANDIDATE_SHA" "--spec=$SPEC" "--out=$OUT")
if ((${#PASSTHRU[@]})); then RUN_ARGS+=("${PASSTHRU[@]}"); fi

RUN_LOG="$(mktemp -t atd-gate.XXXXXX)"
trap 'rm -f "$RUN_LOG"' EXIT
set +e
node "$RUN_MJS" "${RUN_ARGS[@]}" >"$RUN_LOG" 2>&1
RUN_RC=$?
set -e

SUMMARY="$(sed -n 's/^ATD_SUMMARY=//p' "$RUN_LOG" | tail -n 1)"
echo "ATD discovery gate (mode=$MODE) base=${BASE} candidate=${CANDIDATE_SHA}"

if [[ -z "$SUMMARY" || ! -f "$SUMMARY" ]]; then
  echo "status: pipeline_error (no round summary was produced; exit $RUN_RC)"
  tail -n 15 "$RUN_LOG" | sed 's/^/  /'
  echo "NOT A PASS CLAIM: the discovery pipeline did not complete."
  if [[ "$MODE" == "block" ]]; then exit $([[ "$RUN_RC" == "2" ]] && echo 2 || echo 13); fi
  echo "warn-only: exiting 0; the failure is recorded above and in the output directory $OUT"
  exit 0
fi

ROUND_DIR="$(dirname "$SUMMARY")"
STATUS="$(jq -r '.status' "$SUMMARY")"
RESULTS="$ROUND_DIR/results.json"

REC_FILE=""
REC_RC=0
if [[ -f "$RESULTS" ]]; then
  REC_FILE="$ROUND_DIR/repair-recommendation.json"
  set +e
  node "$REPAIR_MJS" "--results=$RESULTS" "--ledger-dir=$OUT/repair" "--candidate-commit=$CANDIDATE_SHA" \
    "--max-attempts=$MAX_ATTEMPTS" "--max-requests=$MAX_REQUESTS" "--state-dir=$(jq -r '.harness.stateDir // empty' "$SUMMARY")" ${APPROVAL_DIR:+"--approval-dir=$APPROVAL_DIR"} > "$REC_FILE.tmp" 2>"$ROUND_DIR/repair-request.stderr.log"
  REC_RC=$?
  set -e
  if [[ "$REC_RC" == "0" ]]; then mv "$REC_FILE.tmp" "$REC_FILE"; else rm -f "$REC_FILE.tmp"; REC_FILE=""; fi
fi

echo "status: $STATUS"
jq -r '
  (if .harness.verdict then "eval-harness verdict: \(.harness.verdict)" else "eval-harness verdict: (none)" end),
  (if .classificationCounts then "classifications: " + ((.classificationCounts | to_entries | map("\(.key)=\(.value)") | join(" ")) | if . == "" then "(none)" else . end) else "classifications: (none)" end),
  "non-PASS cases preserved: \((.nonPass // []) | length)",
  (if .generation then "generation: transport=\(.generation.transport) model=\((.generation.servedModels // []) | join(",")) calls=\(.generation.modelCalls) real=\(.generation.real)" else "generation: (none)" end),
  (if .candidates then "candidates: accepted=\(.candidates.accepted) rejected=\((.candidates.rejected // []) | length)" else "candidates: (none)" end),
  (if (.errors // []) | length > 0 then "errors: " + ((.errors | map("\(.stage)/\(.code): \(.message)") | join(" | ")) | .[0:400]) else empty end)
' "$SUMMARY"
echo "round summary: $SUMMARY"
[[ -f "$RESULTS" ]] && echo "results: $RESULTS"

# Blocking eligibility comes ONLY from the independent recomputation (grade.sh replay of the preserved grading
# manifests, done inside repair-request.mjs). The round summary and results.json are claims and never decide it.
INDEPENDENT_COUNT=0
UNVERIFIED_COUNT=0
if [[ -n "$REC_FILE" ]]; then
  INDEPENDENT_COUNT="$(jq -r '(.independentVerified // []) | length' "$REC_FILE")"
  UNVERIFIED_COUNT="$(jq -r '[.verification.cases[]? | select(.recomputed != true or .consistent != true)] | length' "$REC_FILE")"
fi
NONPASS_COUNT="$(jq -r '(.nonPass // []) | length' "$SUMMARY")"
if [[ -n "$REC_FILE" ]]; then
  echo "independent verification: replayed=$(jq -r '.verification.replayedCases' "$REC_FILE") independently-verified-regressions=$INDEPENDENT_COUNT unverified-or-inconsistent=$UNVERIFIED_COUNT"
fi
if [[ "$UNVERIFIED_COUNT" != "0" ]]; then
  jq -r '.verification.cases[] | select(.recomputed != true or .consistent != true) | "UNVERIFIED: \(.caseId): \(.reason)"' "$REC_FILE"
fi

if [[ -n "$REC_FILE" ]]; then
  REQ_COUNT="$(jq -r '.requests | length' "$REC_FILE")"
  ADV_COUNT="$(jq -r '.advisories | length' "$REC_FILE")"
  EXH_COUNT="$(jq -r '.exhausted | length' "$REC_FILE")"
  if [[ "$REQ_COUNT" != "0" ]]; then
    jq -r '.requests[] | "repair request: \(.path) finding=\(.request.findingId) attempt=\(.request.attempt)/\(.request.maxAttempts) target=\(.request.targetFile)" ' "$REC_FILE"
  fi
  if [[ "$ADV_COUNT" != "0" ]]; then
    echo "advisory (verified but attestation is not independent, human review; not a repair request): $ADV_COUNT"
  fi
  if [[ "$EXH_COUNT" != "0" ]]; then
    jq -r '.exhausted[] | "REPAIR ATTEMPTS EXHAUSTED: \(.targetFile) after \(.attempts)/\(.maxAttempts); human review required"' "$REC_FILE"
  fi
  jq -r '.skipped[]? | select(.reason | startswith("stale_evidence")) | "STALE EVIDENCE: \(.findingId): \(.reason)"' "$REC_FILE"
elif [[ -f "$RESULTS" ]]; then
  echo "repair recommendation: unavailable (repair-request.mjs exit $REC_RC: $(tail -n 1 "$ROUND_DIR/repair-request.stderr.log" 2>/dev/null)); see $ROUND_DIR/repair-request.stderr.log"
fi

CLEAN=1
case "$STATUS" in completed) ;; *) CLEAN=0 ;; esac
[[ "$NONPASS_COUNT" == "0" ]] || CLEAN=0
if [[ "$CLEAN" == "0" ]]; then
  echo "NOT A PASS CLAIM: status=$STATUS with $NONPASS_COUNT non-PASS case(s); review the preserved artifacts."
elif [[ "$STATUS" == "completed" ]]; then
  echo "no regression observed by the generated tests that ran (this is not proof the change is bug-free)"
fi

EXIT_CODE=0
if [[ "$MODE" == "block" ]]; then
  if [[ "$INDEPENDENT_COUNT" != "0" ]]; then
    echo "BLOCK: $INDEPENDENT_COUNT verified regression(s), independently recomputed from preserved evidence with an independent signer"
    EXIT_CODE=14
  elif [[ -f "$RESULTS" && -z "$REC_FILE" ]]; then
    echo "BLOCK-MODE ERROR: preserved evidence could not be independently re-verified; the gate cannot certify this change"
    EXIT_CODE=13
  elif [[ "$UNVERIFIED_COUNT" != "0" ]]; then
    echo "BLOCK-MODE ERROR: $UNVERIFIED_COUNT case(s) are unverifiable or disagree with their recomputed grading (possible tampering); the gate cannot certify this change"
    EXIT_CODE=13
  else
    case "$STATUS" in
      harness_error|preflight_failed|generation_failed|usage_error) echo "BLOCK-MODE ERROR: pipeline could not certify this change"; EXIT_CODE=13 ;;
    esac
  fi
else
  echo "warn-only: exit 0 regardless of findings; nothing above is a blocking verdict"
fi

jq -n --arg mode "$MODE" --arg status "$STATUS" --argjson exit "$EXIT_CODE" --arg summary "$SUMMARY" --argjson independent "$INDEPENDENT_COUNT" --argjson nonpass "$NONPASS_COUNT" \
  '{schema:"atd.gate/v1",mode:$mode,status:$status,exitCode:$exit,verifiedIndependentFindings:$independent,nonPassCases:$nonpass,summary:$summary}' > "$ROUND_DIR/gate.json"
exit "$EXIT_CODE"
