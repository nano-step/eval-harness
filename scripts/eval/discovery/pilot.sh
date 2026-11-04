#!/usr/bin/env bash
# scripts/eval/discovery/pilot.sh — collision benchmark pilot for Autonomous Test Discovery.
#
#   pilot.sh run     --dependencies=<snapshot> [--out=<dir>] [--model=<provider/model[:thinking]>] [--skip-mutation]
#   pilot.sh replay  --out=<pilot dir> --dependencies=<snapshot> --approval-dir=<trusted operator dir>
#   pilot.sh gate    --out=<pilot dir> --dependencies=<snapshot>
#   pilot.sh qa-hook --out=<pilot dir> --dependencies=<snapshot> [--qa-src=<qa-agents-factory/src>] [--qa-python=<python>]
#   pilot.sh report  --out=<pilot dir>
#
# `run` performs REAL work and spends model calls: it builds the isolated fixture repository, then drives the
# real pipeline (run.mjs: one bounded OMP generation call per round on the configured `implement` role ->
# deterministic validation -> existing eval-harness run.sh + atd-sandbox, 3 stability samples) for
#   clean   : base -> clean-change (a behaviour-preserving refactor; must not be flagged)
#   defect  : base -> boundary-defect (touching edges counted as overlap; the baseline tests still pass)
#   mutation: scoped StrykerJS INSIDE the sandbox on the clean revision, baseline tests vs. accepted
#             mutation-guided generated tests (surviving -> killed evidence)
# and finally writes pilot-report.json from the artifacts that were actually produced. Nothing is mocked,
# no generated test runs on the host, and unmeasured values stay null.
#
# Findings stay SUSPECTED until an operator reviews the generated test against SPEC.md and supplies an
# expectation-review record bound to the signed hashes (see <round>/review/*.template.json). `replay` then
# re-evaluates the SAME candidates (no model call) with that trusted review.
#
# Prerequisites (not installed or pulled by this script): docker with the pinned node image, jq, git, node,
# omp with a Sonnet `implement` role, and a dependency snapshot built by scripts/eval/discovery/setup-deps.sh
#   setup-deps.sh --lockfile-dir=examples/discovery-pilot/collision --allow-network

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS_ROOT="$(cd "$SELF_DIR/../../.." && pwd)"
FIXTURE_SRC="$HARNESS_ROOT/examples/discovery-pilot/collision"
RUN_MJS="$SELF_DIR/run.mjs"
GATE_SH="$SELF_DIR/jev-gate.sh"

die() { echo "[pilot] $*" >&2; exit 2; }
info() { echo "[pilot] $*" >&2; }

SUBCOMMAND="${1:-}"
[[ -n "$SUBCOMMAND" ]] || { sed -n '2,29p' "${BASH_SOURCE[0]}"; exit 2; }
shift
case "$SUBCOMMAND" in -h|--help) sed -n '2,29p' "${BASH_SOURCE[0]}"; exit 0 ;; run|replay|gate|qa-hook|report) ;; *) die "unknown subcommand '$SUBCOMMAND'" ;; esac

OUT="" DEPS="" MODEL="" APPROVALS="" QA_SRC="" QA_PY="" SKIP_MUTATION=0
for arg in "$@"; do
  case "$arg" in
    --out=*)          OUT="${arg#*=}" ;;
    --dependencies=*) DEPS="${arg#*=}" ;;
    --model=*)        MODEL="${arg#*=}" ;;
    --approval-dir=*) APPROVALS="${arg#*=}" ;;
    --qa-src=*)       QA_SRC="${arg#*=}" ;;
    --qa-python=*)    QA_PY="${arg#*=}" ;;
    --skip-mutation)  SKIP_MUTATION=1 ;;
    *) die "unknown argument: $arg" ;;
  esac
done

for tool in node jq git; do command -v "$tool" >/dev/null 2>&1 || die "$tool is required"; done

sha256_file() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }

need_out() { [[ -n "$OUT" ]] || die "--out=<pilot dir> is required"; OUT="$(cd "$OUT" && pwd -P)"; [[ -f "$OUT/fixture/fixture.json" ]] || die "$OUT is not a pilot directory (fixture/fixture.json missing)"; }
need_deps() {
  [[ -n "$DEPS" && -d "$DEPS/node_modules" && -f "$DEPS/package-lock.json" ]] || die "--dependencies must be a snapshot built by setup-deps.sh (node_modules + package-lock.json)"
  DEPS="$(cd "$DEPS" && pwd -P)"
  [[ "$(sha256_file "$DEPS/package-lock.json")" == "$(sha256_file "$FIXTURE_SRC/package-lock.json")" ]] || die "dependency snapshot lockfile differs from the fixture lockfile; rebuild it with setup-deps.sh"
}
need_docker() { docker version --format '{{.Server.Version}}' >/dev/null 2>&1 || die "docker daemon is not reachable (the sandbox fails closed; there is no host fallback)"; }

fixture_field() { jq -r "$1" "$OUT/fixture/fixture.json"; }

common_args() {
  REPO="$(fixture_field .repository)"
  BASE="$(fixture_field .baseCommit)"
  CLEAN="$(fixture_field .revisions.clean.commit)"
  BOUNDARY="$(fixture_field .revisions.boundaryDefect.commit)"
  STATE="$OUT/eval-state"
  COMMON=("--repo=$REPO" "--spec=$REPO/SPEC.md" "--dependencies=$DEPS" "--state-dir=$STATE" "--framework=vitest")
  if [[ -n "$MODEL" ]]; then COMMON+=("--model=$MODEL"); fi
}

# step <label> <cmd...>: run, record the exit code, never abort the pilot on a pipeline failure.
FAILED_STEPS=()
step() {
  local label="$1"; shift
  info "step: $label"
  set +e
  "$@" 2>&1 | tee -a "$OUT/pilot.log" >&2
  local rc="${PIPESTATUS[0]}"
  set -e
  echo "$label exit=$rc" >> "$OUT/steps.log"
  if [[ "$rc" != "0" ]]; then FAILED_STEPS+=("$label (exit $rc)"); fi
  return 0
}

write_report() {
  node "$RUN_MJS" pilot-report "--out=$OUT" | tee -a "$OUT/pilot.log"
}

print_report_summary() {
  local file="$1"
  jq -r '"expectations:", (.expectations[] | "  [\(if .met==true then "met" elif .met==false then "NOT MET" else "pending" end)] \(.id)"),
         "metrics: modelCalls=\(.metrics.generation.modelCalls) generationSuccess=\(.metrics.generation.successRate.numerator)/\(.metrics.generation.successRate.denominator) candidates(generated/staticAccepted/operatorApproved)=\(.metrics.candidates.generatedByModel)/\(.metrics.candidates.staticallyAccepted)/\(.metrics.candidates.operatorApproved) detection(any/confirmed)=\(.metrics.detection.detectionAny.numerator)/\(.metrics.detection.detectionAny.denominator),\(.metrics.detection.confirmedDetection.numerator)/\(.metrics.detection.confirmedDetection.denominator) falsePositive(change)=\(.metrics.detection.falsePositiveChangeLevel.numerator)/\(.metrics.detection.falsePositiveChangeLevel.denominator) mutationScore(baseline→with tests)=\(.metrics.mutation.baselineScore)→\(.metrics.mutation.scoreWithGeneratedTests) tokens(in/out)=\(.metrics.generation.usage.input)/\(.metrics.generation.usage.output) costUsd=\(.metrics.generation.usage.costUsd)"' "$file" >&2
}

report_exit_code() {
  local file="$1"
  if jq -e '[.expectations[] | select(.met==false)] | length > 0' "$file" >/dev/null; then return 1; fi
  if ((${#FAILED_STEPS[@]})); then return 13; fi
  return 0
}

case "$SUBCOMMAND" in
# --------------------------------------------------------------------------------------------------------------
run)
  need_deps
  command -v docker >/dev/null 2>&1 || die "docker is required"
  need_docker
  command -v omp >/dev/null 2>&1 || die "omp is required for the real generation call"
  [[ -n "$OUT" ]] || OUT="${TMPDIR:-/tmp}/atd-pilot-$(date -u +%Y%m%dT%H%M%SZ)"
  if [[ -e "$OUT" ]] && [[ -n "$(ls -A "$OUT" 2>/dev/null)" ]]; then die "--out already exists and is not empty (pilot evidence is never overwritten): $OUT"; fi
  mkdir -p "$OUT/fixture" "$OUT/eval-state"
  OUT="$(cd "$OUT" && pwd -P)"
  : > "$OUT/steps.log"

  bash "$FIXTURE_SRC/build-fixture-repo.sh" "$OUT/fixture/repo" > "$OUT/fixture/fixture.raw.json"
  jq --arg node "$(node --version)" --arg docker "$(docker version --format '{{.Server.Version}}')" --arg omp "$(omp --version 2>/dev/null || echo unknown)" --arg git "$(git --version)" \
     --arg image "$(jq -r '.image.ref' "$SELF_DIR/policy/atd-sandbox.v1.json")" --arg lock "$(sha256_file "$DEPS/package-lock.json")" --arg at "$(date -u +%FT%TZ)" \
     '. + {environment:{hostNode:$node,docker:$docker,omp:$omp,git:$git,sandboxImage:$image,lockfileSha256:$lock,startedAt:$at}}' "$OUT/fixture/fixture.raw.json" > "$OUT/fixture/fixture.json"
  rm -f "$OUT/fixture/fixture.raw.json"
  common_args
  node "$RUN_MJS" pilot-snapshot "--out=$OUT" --name=before >/dev/null

  step "clean round (intent-aware generation)" node "$RUN_MJS" run "${COMMON[@]}" --base="$BASE" --candidate="$CLEAN" --out="$OUT/clean"
  step "defect round (intent-aware generation)" node "$RUN_MJS" run "${COMMON[@]}" --base="$BASE" --candidate="$BOUNDARY" --out="$OUT/defect"

  if [[ "$SKIP_MUTATION" != "1" ]]; then
    if [[ -f "$OUT/clean/round-001/risk.json" ]]; then
      step "mutation baseline (Stryker in sandbox, baseline tests)" node "$RUN_MJS" mutation-evidence --repo="$REPO" --commit="$CLEAN" --risk="$OUT/clean/round-001/risk.json" --dependencies="$DEPS" --state-dir="$STATE" --out="$OUT/mutation/baseline"
      if [[ -f "$OUT/mutation/baseline/normalized.json" ]]; then
        step "clean round 2 (mutation-guided generation)" node "$RUN_MJS" run "${COMMON[@]}" --base="$BASE" --candidate="$CLEAN" --out="$OUT/clean" --mutation-report="$OUT/mutation/baseline/normalized.json"
        if [[ -f "$OUT/clean/round-002/round-summary.json" ]]; then
          step "mutation with accepted generated tests" node "$RUN_MJS" mutation-evidence --repo="$REPO" --commit="$CLEAN" --risk="$OUT/clean/round-002/risk.json" --dependencies="$DEPS" --state-dir="$STATE" --round="$OUT/clean/round-002" --baseline="$OUT/mutation/baseline" --out="$OUT/mutation/with-generated-tests"
        fi
      else
        info "no baseline mutation report; the mutation-guided steps are skipped and reported as unavailable"
      fi
    else
      info "clean round produced no risk report; mutation steps skipped"
    fi
  fi

  node "$RUN_MJS" pilot-snapshot "--out=$OUT" --name=after >/dev/null
  REPORT_LINE="$(write_report)"
  REPORT_FILE="${REPORT_LINE#ATD_PILOT_REPORT=}"
  print_report_summary "$REPORT_FILE"
  echo "pilot output: $OUT"
  echo "report: $REPORT_FILE"
  if jq -e '[.expectations[] | select(.met==null)] | length > 0' "$REPORT_FILE" >/dev/null; then echo "some expectations are pending (see report); VERIFIED needs the operator review + replay"; fi
  ((${#FAILED_STEPS[@]})) && printf 'failed step: %s\n' "${FAILED_STEPS[@]}" >&2
  report_exit_code "$REPORT_FILE" || exit $?
  ;;
# --------------------------------------------------------------------------------------------------------------
replay)
  need_out; need_deps
  [[ -n "$APPROVALS" && -d "$APPROVALS" ]] || die "--approval-dir=<trusted operator directory> is required"
  APPROVALS="$(cd "$APPROVALS" && pwd -P)"
  case "$APPROVALS" in "$OUT"|"$OUT"/*) die "--approval-dir must be outside the pilot output directory (generator-owned artifacts live there)" ;; esac
  need_docker
  common_args
  LATEST=""
  for d in "$OUT"/defect/round-*; do
    [[ -f "$d/round-summary.json" ]] || continue
    if jq -e '.status=="completed" and (.generation.real==true)' "$d/round-summary.json" >/dev/null; then LATEST="$d"; fi
  done
  [[ -n "$LATEST" ]] || die "no completed defect round with a real generation call to replay"
  step "defect review replay (no model call)" node "$RUN_MJS" run "${COMMON[@]}" --base="$BASE" --candidate="$BOUNDARY" --out="$OUT/defect" --reevaluate="$LATEST" --approval-dir="$APPROVALS"
  REPORT_LINE="$(write_report)"
  REPORT_FILE="${REPORT_LINE#ATD_PILOT_REPORT=}"
  print_report_summary "$REPORT_FILE"
  echo "report: $REPORT_FILE"
  report_exit_code "$REPORT_FILE" || exit $?
  ;;
# --------------------------------------------------------------------------------------------------------------
gate)
  need_out; need_deps; need_docker
  common_args
  mkdir -p "$OUT/gate-run"
  info "Jev gate (warn-only) on the boundary defect; this makes one real generation call"
  set +e
  bash "$GATE_SH" --repo="$REPO" --base="$BASE" --candidate="$BOUNDARY" --spec="$REPO/SPEC.md" --dependencies="$DEPS" --out="$OUT/gate" --state-dir="$STATE" --mode=warn ${MODEL:+--model="$MODEL"} 2>&1 | tee "$OUT/gate-run/gate.stdout.txt"
  GATE_RC="${PIPESTATUS[0]}"
  set -e
  echo "gate exit code: $GATE_RC (warn mode always exits 0 by contract)"
  ;;
# --------------------------------------------------------------------------------------------------------------
qa-hook)
  need_out; need_deps; need_docker
  common_args
  QA_DIR="$OUT/qa"; mkdir -p "$QA_DIR"
  NODE_BIN="$(command -v node)"
  render() {
    sed -e "s|@@EVAL_HARNESS_ROOT@@|$HARNESS_ROOT|g" -e "s|@@WORK@@|$QA_DIR|g" -e "s|@@NODE@@|$NODE_BIN|g" -e "s|@@FIXTURE_REPO@@|$REPO|g" \
        -e "s|@@DEPENDENCIES@@|$DEPS|g" -e "s|@@BASE_COMMIT@@|$BASE|g" -e "s|@@DEFECT_COMMIT@@|$BOUNDARY|g" "$FIXTURE_SRC/config/$1" > "$2"
  }
  render qa-hook-config.example.json "$QA_DIR/qa-hook-config.json"
  # QA Factory defaults hook_seconds to 30; the real pipeline needs far longer, so the config documents it below.
  jq --arg state "$STATE" --arg model "$MODEL" '.stateDir=$state | if $model != "" then .profiles["collision-boundary"].model=$model | .profiles["collision-boundary"].requireModel=("^" + ($model | split(":")[0] | gsub("[.]"; "[.]")) + "$") else . end' "$QA_DIR/qa-hook-config.json" > "$QA_DIR/qa-hook-config.tmp" && mv "$QA_DIR/qa-hook-config.tmp" "$QA_DIR/qa-hook-config.json"
  render qa-oracle-hook.example.json "$QA_DIR/hook.json"
  render qa-hook-request.example.json "$QA_DIR/request.json"
  jq --arg id "atd-collision-$(date -u +%H%M%S)" '.operation_id=$id' "$QA_DIR/request.json" > "$QA_DIR/request.tmp" && mv "$QA_DIR/request.tmp" "$QA_DIR/request.json"
  HOOK_CMD="$(jq -c '.command' "$QA_DIR/hook.json")"
  QA_SRC="${QA_SRC:-$HARNESS_ROOT/../qa-agents-factory/src}"
  QA_PY="${QA_PY:-$QA_SRC/../.venv/bin/python}"
  if [[ -d "$QA_SRC/qa_factory" && -x "$QA_PY" ]]; then
    info "invoking through qa_factory.hooks.command_hook (QA Factory's own executable allowlist, env scrub and bounds)"
    "$QA_PY" "$HARNESS_ROOT/integrations/qa-factory/command_hook_smoke.py" --qa-src "$QA_SRC" --hook-command-json "$HOOK_CMD" --payload-json "$(jq -c . "$QA_DIR/request.json")" --hook-seconds 3600 > "$QA_DIR/result.json"
  else
    die "qa-agents-factory checkout/venv not found (pass --qa-src=<.../src> and --qa-python=<python with its deps>); the adapter was not exercised through command_hook"
  fi
  jq '{namespace,status,verdict,classification,reviewRequired,reviewReasons,findings:[.findings[]|{findingId,qaClassification,discoveryClassification,matrix,reproducible}],recommendations,errors}' "$QA_DIR/result.json"
  echo "QA hook result: $QA_DIR/result.json"
  ;;
# --------------------------------------------------------------------------------------------------------------
report)
  need_out
  REPORT_LINE="$(write_report)"
  REPORT_FILE="${REPORT_LINE#ATD_PILOT_REPORT=}"
  print_report_summary "$REPORT_FILE"
  ;;
esac
