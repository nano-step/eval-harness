#!/usr/bin/env bash
# scripts/eval/run.sh — entrypoint. Executes one or more cases for a skill.
# Settled Decisions: 3-trigger model, single-tier in v0.1.0, ephemeral sandbox per case,
# run-all-checks, 3-sample stability on FAIL, exit code 12 on regression, 13 on harness error.

set -euo pipefail

_resolve_script_dir() {
  local src="${BASH_SOURCE[0]}"
  while [[ -L "$src" ]]; do
    local dir; dir="$(cd "$(dirname "$src")" && pwd)"
    src="$(readlink "$src")"
    [[ "$src" != /* ]] && src="$dir/$src"
  done
  cd "$(dirname "$src")" && pwd
}
RUN_SCRIPT_DIR="$(_resolve_script_dir)"
LIB="$RUN_SCRIPT_DIR/lib"
source "$LIB/yq-shim.sh"
source "$LIB/skills_root.sh"
source "$LIB/config.sh"
source "$LIB/registry.sh"
source "$LIB/lock.sh"
source "$LIB/runner.sh"
source "$LIB/preflight.sh"
source "$LIB/manifest.sh"
source "$LIB/grading_manifest.sh"
source "$LIB/spawn.sh"
source "$LIB/score.sh"
source "$LIB/diff.sh"
source "$LIB/stability.sh"
source "$LIB/report_junit.sh"
source "$LIB/report_sarif.sh"
source "$LIB/pricing.sh"
source "$LIB/portable.sh"
source "$LIB/stats.sh"
source "$LIB/perf.sh"
source "$LIB/budget.sh"

VERSION="0.5.0"

# Subcommand dispatch: `eval-harness <cmd> ...` routes to the sibling script so the CLI
# surface promised in the README/issues (baseline, status, promote, trend, accept, apply)
# actually works through the single npm bin. Bare flags / `run` fall through to the runner.
case "${1:-}" in
  baseline|status|promote|trend|accept|apply|ab|rebaseline|metaeval|calibrate|grade)
    _sub="$1"; shift
    exec bash "$RUN_SCRIPT_DIR/$_sub.sh" "$@"
    ;;
esac
usage() {
  cat <<'EOF'
eval-harness v$VERSION — opencode skill regression detector

Usage:
  eval-harness run [options]
  eval-harness grade --manifest=<grading-manifest.json> [--strict]

Options:
  --skill=<name>          Skill to evaluate (looks in \$OPENCODE_SKILLS_ROOT)
  --case=<id>             Run only this case (default: all cases for skill)
  --trigger=<name>        Tag the run (manual|pre-push|sync-publish)
  --mode=<smoke|full|2tier>  smoke=cheap+samples=1, full=configured+samples=3,
                             2tier=smoke first, escalate to full on FAIL (default smoke)
  --debug                 Verbose log + keep sandbox dirs
  --pin-env=baseline      Re-run with baseline's env-manifest pinned
  --stability-samples=N   On FAIL re-run case N-1 more times; diagnostic only (default 1)
  --runner=<name>         Runner adapter: opencode (default) | langgraph-node | <custom>
                          A case YAML's runner must match this if both are set.
  --max-regressions=N     Blocking regression count threshold (optional)
  --report=<junit|sarif>:<path>  Write a JUnit XML or SARIF report (repeatable)
  --dry-run               Print plan; don't spawn opencode
  -h, --help              Show this help

2-tier defaults (override via env):
  EVAL_SMOKE_MODEL        anthropic/claude-3-5-haiku-latest
  EVAL_FULL_MODEL         \$EVAL_MODEL or anthropic/claude-sonnet-4-6
  EVAL_SMOKE_SAMPLES      1
  EVAL_FULL_SAMPLES       3

Environment:
  OPENCODE_SKILLS_ROOT     Override skills root. If unset: walks up from cwd
                           for .opencode/skills/, else \$HOME/.config/opencode/skills
  EVAL_BUDGET_USD          Optional daily hard cap (unset disables the cap)
  EVAL_MAX_SECONDS         Per-case timeout (default: 180)
  EVAL_MODEL               Override model (default: anthropic/claude-haiku-3-5)
  EVAL_RUNNER              Default runner adapter (overridden per-case by case YAML `runner:`)
  EVAL_BYPASS              Set to 1 to skip evals (logged to history.ndjson)

Exit codes:
  0    Passing result, or warn-only gate result
  12   Regression count exceeds configured limit or blocking regression
  13   Harness or grader execution error
  14   Strict evaluation failure
  15   Strict evaluation requires human review
  16   Strict evaluation is indeterminate due to unavailable evidence
  Warn-only outcomes retain their non-PASS status in results.json.
EOF
}

SKILL=""
CASE_ID=""
TRIGGER="manual"
DEBUG=0
DRY_RUN=0
PIN_ENV=""
MODE="${EVAL_MODE:-smoke}"
STABILITY_SAMPLES="${EVAL_STABILITY_SAMPLES:-1}"
RUNNER_OPT="${EVAL_RUNNER:-}"
STRICT="${EVAL_STRICT:-0}"
MAX_REGRESSIONS=""
REPORTS="${EVAL_REPORTS:-}"

for arg in "$@"; do
  case "$arg" in
    --skill=*)               SKILL="${arg#*=}" ;;
    --case=*)                CASE_ID="${arg#*=}" ;;
    --trigger=*)             TRIGGER="${arg#*=}" ;;
    --mode=*)                MODE="${arg#*=}" ;;
    --strict)                STRICT=1 ;;
    --max-regressions=*)      MAX_REGRESSIONS="$(printf '%s' "$arg" | sed 's/^[^=]*=//')" ;;
    --report=*)              REPORTS="${REPORTS:+$REPORTS,}${arg#*=}" ;;
    --debug)                 DEBUG=1 ;;
    --dry-run)               DRY_RUN=1 ;;
    --pin-env=*)             PIN_ENV="${arg#*=}" ;;
    --stability-samples=*)   STABILITY_SAMPLES="${arg#*=}" ;;
    --runner=*)              RUNNER_OPT="${arg#*=}" ;;
    -h|--help)               usage; exit 0 ;;
    --version)              echo "eval-harness v$VERSION"; exit 0 ;;
    run)                     ;;
    *) echo "unknown arg: $arg" >&2; usage >&2; exit 2 ;;
  esac
done
if [[ -n "$CASE_ID" && ! "$CASE_ID" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
  echo "[eval-harness] invalid --case id '$CASE_ID' (use letters, digits, dot, underscore, or hyphen)" >&2
  exit 2
fi

# Propagate --runner into the EVAL_RUNNER env var so the case loop can
# read it for per-invocation resolution. Empty means "use case YAML or
# fall back to opencode default".
if [[ -n "$RUNNER_OPT" ]]; then
  export EVAL_RUNNER="$RUNNER_OPT"
fi

case "$MODE" in
  smoke|full|2tier) ;;
  *) echo "[eval-harness] invalid --mode='$MODE' (smoke|full|2tier)" >&2; exit 2 ;;
esac

if [[ -n "$MAX_REGRESSIONS" ]] && ! [[ "$MAX_REGRESSIONS" =~ ^[0-9]+$ ]]; then
  echo "[eval-harness] invalid --max-regressions='$MAX_REGRESSIONS' (must be a nonnegative integer)" >&2
  exit 2
fi
if ! [[ "$STABILITY_SAMPLES" =~ ^[1-9][0-9]*$ ]]; then
  echo "[eval-harness] invalid --stability-samples='$STABILITY_SAMPLES' (must be positive integer)" >&2
  exit 2
fi

apply_mode_defaults() {
  local mode="$1"
  case "$mode" in
    smoke)
      export EVAL_MODEL="${EVAL_SMOKE_MODEL:-anthropic/claude-3-5-haiku-latest}"
      export EVAL_LLM_JUDGE_SAMPLES="${EVAL_SMOKE_SAMPLES:-1}"
      ;;
    full)
      export EVAL_MODEL="${EVAL_FULL_MODEL:-${EVAL_MODEL:-anthropic/claude-sonnet-4-6}}"
      export EVAL_LLM_JUDGE_SAMPLES="${EVAL_FULL_SAMPLES:-3}"
      ;;
  esac
}

# Dispatch one case invocation through the selected runner. Each adapter owns its argv contract.
_spawn_case_runner() {
  local prompt="$1" workdir="$2" sandbox="$3" transcript="$4"; shift 4
  local runner_config_json input_file output_file
  runner_config_json="$(yq -o=json '.runner_config // {}' "$EVAL_CASE_FILE" 2>/dev/null || echo '{}')"
  case "$EFFECTIVE_RUNNER" in
    opencode)
      spawn_runner opencode "$prompt" "$workdir" "$sandbox" "$transcript" "$@" ;;
    langgraph-node)
      input_file="$(printf '%s' "$runner_config_json" | jq -r '.input // "input.json"')"
      output_file="$(printf '%s' "$runner_config_json" | jq -r '.output // "output.json"')"
      spawn_runner langgraph-node "$workdir" "$workdir/$input_file" "$workdir/$output_file" "$transcript" "$runner_config_json" ;;
    *)
      spawn_runner "$EFFECTIVE_RUNNER" "$workdir" "$runner_config_json" "$transcript" "$prompt" ;;
  esac
}

if [[ -z "$SKILL" ]]; then
  echo "error: --skill=<name> is required" >&2
  usage >&2
  exit 2
fi

STATE_DIR="${EVAL_STATE_DIR:-$HOME/.config/opencode/eval-harness}"
mkdir -p "$STATE_DIR/locks" "$STATE_DIR/runs"
HISTORY_LOG="$STATE_DIR/history.ndjson"
touch "$HISTORY_LOG"

append_history_line() {
  local line="$1"
  local hist_lock="$STATE_DIR/locks/history.ndjson.lock"
  if command -v flock >/dev/null 2>&1; then
    (
      exec 8>"$hist_lock"
      flock -w 10 -x 8 || true
      printf '%s\n' "$line" >> "$HISTORY_LOG"
    )
  else
    local mkdir_lock="${hist_lock}.d"
    local waited=0
    while ! mkdir "$mkdir_lock" 2>/dev/null; do
      if [[ "$waited" -ge 100 ]]; then break; fi
      sleep 0.1
      waited=$((waited+1))
    done
    printf '%s\n' "$line" >> "$HISTORY_LOG"
    rmdir "$mkdir_lock" 2>/dev/null || true
  fi
}

log_bypass_event() {
  local skill="$1"; local trigger="$2"
  append_history_line "$(jq -nc --arg ts "$(date -u +%FT%TZ)" --arg s "$skill" --arg t "$trigger" '{event:"bypass",timestamp:$ts,skill:$s,trigger:$t}')"
}

if [[ "${EVAL_BYPASS:-0}" == "1" ]]; then
  echo "[eval-harness] EVAL_BYPASS=1 — skipping eval, logging bypass" >&2
  log_bypass_event "$SKILL" "$TRIGGER"
  exit 0
fi

apply_project_config

if [[ "$MODE" == "2tier" ]]; then
  exec bash "$RUN_SCRIPT_DIR/twotier.sh" "$@"
fi

if [[ "$MODE" == "smoke" || "$MODE" == "full" ]]; then
  apply_mode_defaults "$MODE"
fi

case "$TRIGGER" in
  pre-push|sync-publish|stop-hook)
    repo_name="$(repo_name_from_path "$(pwd)")"
    if ! registry_is_enabled "$repo_name"; then
      echo "[eval-harness] repo '$repo_name' not in registry — skipping ($TRIGGER trigger)" >&2
      echo "[eval-harness] enable with: bash scripts/eval/lib/registry.sh enable $repo_name" >&2
      exit 0
    fi
    ;;
esac

# Pre-scan case files to determine which runners are needed, then run
# preflight for each. This handles mixed-runner case sets where the CLI
# didn't pin --runner: e.g., one opencode case + one langgraph-node case
# should preflight both, not fail on the first preflight_check.
# NOTE: this must happen *before* CASE_FILES is defined below (lines
# 218-222). Without this ordering, _NEEDED_RUNNERS is empty and preflight
# for every runner (including the default opencode) is silently bypassed.
_NEEDED_RUNNERS=""
add_needed_runner() {
  local candidate="$1"
  case $'\n'"$_NEEDED_RUNNERS"$'\n' in
    *$'\n'"$candidate"$'\n'*) return 0 ;;
  esac
  _NEEDED_RUNNERS="${_NEEDED_RUNNERS}${candidate}"$'\n'
}
if [[ -n "${CASE_ID:-}" ]]; then
  _PRE_CASES_DIR="$(resolve_skills_root)/$SKILL/evals/cases"
  if [[ -f "$_PRE_CASES_DIR/$CASE_ID.yaml" ]]; then
    _PRE_CASE_FILES="$_PRE_CASES_DIR/$CASE_ID.yaml"
  else
    _PRE_CASE_FILES=""
  fi
else
  _PRE_CASES_DIR="$(resolve_skills_root)/$SKILL/evals/cases"
  _PRE_CASE_FILES=""
  if [[ -d "$_PRE_CASES_DIR" ]]; then
    _PRE_CASE_FILES="$(find "$_PRE_CASES_DIR" -maxdepth 1 -type f -name "*.yaml" | sort)"
  fi
fi
while IFS= read -r _cf; do
  [[ -n "$_cf" ]] || continue
  [[ -f "$_cf" ]] || continue
  _cr="$(yq -r '.runner // "opencode"' "$_cf" 2>/dev/null || echo "opencode")"
  add_needed_runner "$_cr"
done <<EOF
$_PRE_CASE_FILES
EOF
while IFS= read -r _r; do
  [[ -n "$_r" ]] || continue
  case "$_r" in
    opencode)       if ! preflight_check;          then exit 13; fi ;;
    langgraph-node) if ! preflight_check_langgraph; then exit 13; fi ;;
    *)
      echo "[eval-harness] unknown runner '$_r' in case files" >&2
      exit 13
      ;;
  esac
done <<EOF
$_NEEDED_RUNNERS
EOF
unset -f add_needed_runner
unset _NEEDED_RUNNERS _cr _cf _r _PRE_CASES_DIR _PRE_CASE_FILES

SKILLS_ROOT="$(resolve_skills_root)"
SKILL_DIR="$SKILLS_ROOT/$SKILL"
EVALS_DIR="$SKILL_DIR/evals"
CASES_DIR="$EVALS_DIR/cases"
BASELINES_DIR="$EVALS_DIR/baselines"
FIXTURES_DIR="$EVALS_DIR/fixtures"

if [[ ! -d "$CASES_DIR" ]]; then
  echo "[eval-harness] no evals found for skill '$SKILL' at $CASES_DIR" >&2
  exit 13
fi

RUN_ID="$(date -u +%Y-%m-%dT%H-%M-%SZ)-$RANDOM"
_RUN_START_MS="$(_now_ms)"
RUN_DIR="$STATE_DIR/runs/$RUN_ID"
mkdir -p "$RUN_DIR"

if [[ -n "$CASE_ID" ]]; then
  CASE_FILES=("$CASES_DIR/$CASE_ID.yaml")
else
  CASE_FILES=()
  while IFS= read -r _case_path; do
    [[ -n "$_case_path" ]] && CASE_FILES+=("$_case_path")
  done < <(find "$CASES_DIR" -maxdepth 1 -type f -name "*.yaml" | sort)
fi

if [[ ${#CASE_FILES[@]} -eq 0 ]]; then
  echo "[eval-harness] no case files matched for skill=$SKILL case=$CASE_ID" >&2
  exit 13
fi

if [[ "$DRY_RUN" != "1" ]] && ! budget_precheck; then
  exit 13
fi

echo "[eval-harness] v$VERSION trigger=$TRIGGER skill=$SKILL cases=${#CASE_FILES[@]}"
echo "[eval-harness] run_id=$RUN_ID"

PRICING_STALENESS="$(pricing_staleness_check)"
PRICING_STATUS="$(echo "$PRICING_STALENESS" | jq -r '.status')"
case "$PRICING_STATUS" in
  STALE)
    echo "[eval-harness] WARN: $(echo "$PRICING_STALENESS" | jq -r '.message')" >&2
    if [[ "${EVAL_FAIL_ON_STALE_PRICING:-0}" == "1" ]]; then
      echo "[eval-harness] EVAL_FAIL_ON_STALE_PRICING=1 — refusing to run" >&2
      exit 13
    fi
    ;;
  MISSING|INVALID)
    echo "[eval-harness] note: pricing data $PRICING_STATUS — cost data will be null" >&2
    ;;
esac

case_results=()
_case_error_result() {
  local cid="$1" expected="$2" actual="$3" hint="$4"
  jq -n --arg cid "$cid" --arg expected "$expected" --arg actual "$actual" --arg hint "$hint" '{
    case_id:$cid,passed:false,status:"ERROR",evaluation_type:"regression",compare_to_baseline:false,baseline_passed:null,regression:false,
    checks:[{kind:"harness_error",required:true,passed:false,status:"ERROR",error:true,failed_check_id:("harness:"+$cid),expected:$expected,actual:$actual,diff_hint:$hint}],
    quality:{dimensions:{},aggregate:null},reliability:null,stochastic:null,
    attribution:{top:"NOT_COMPARED",also_observed:[],evidence:{}},env_delta:{keys_changed:["__no_baseline__"],details:{}},
    stability:{status:"not_run"},env_manifest:{},cost:{status:"unavailable",usd:null,reason:"case did not execute"},
    resources:{tokens:{status:"unavailable",input_tokens:null,output_tokens:null},cost:{status:"unavailable",usd:null}}
  }'
}
i=0
for case_file in "${CASE_FILES[@]}"; do
  i=$((i+1))
  if [[ ! -f "$case_file" ]]; then
    echo "[eval-harness] case file missing: $case_file" >&2
    missing_id="${CASE_ID:-$(basename "$case_file" .yaml)}"
    case_results+=("$(_case_error_result "$missing_id" "case file exists" "missing: $case_file" "case registry selected a missing case file")")
    continue
  fi
  _case_start_ms="$(_now_ms)"   # (#EV-P)
  cid="$(yq -r '.id' "$case_file")"
  if ! [[ "$cid" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    case_results+=("$(_case_error_result "${cid:-unknown}" "path-safe case id" "$cid" "case id must contain only letters, digits, dot, underscore, or hyphen")")
    continue
  fi
  prompt="$(yq -r '.prompt' "$case_file")"
  description="$(yq -r '.description // ""' "$case_file")"
  skills_loaded=()
  while IFS= read -r _loaded_skill; do
    [[ -n "$_loaded_skill" ]] && skills_loaded+=("$_loaded_skill")
  done < <(yq -r '.skills_loaded[]' "$case_file" 2>/dev/null || true)
  [[ ${#skills_loaded[@]} -eq 0 ]] && skills_loaded=("$SKILL")

  case_model="$(yq -r '.model // ""' "$case_file" 2>/dev/null || echo "")"
  ab_model_override="$(printenv EVAL_AB_MODEL_OVERRIDE 2>/dev/null || echo "")"
  if [[ -n "$ab_model_override" ]]; then
    export EVAL_CASE_MODEL="$ab_model_override"
  elif [[ -n "$case_model" ]]; then
    export EVAL_CASE_MODEL="$case_model"
  else
    unset EVAL_CASE_MODEL
  fi

  # Per-invocation runner resolution: CLI selection must agree with case runner.
  case_runner="$(yq -r '.runner // ""' "$case_file" 2>/dev/null || echo "")"
  if [[ -n "$case_runner" ]]; then
    if [[ -n "${EVAL_RUNNER:-}" && "${EVAL_RUNNER}" != "$case_runner" ]]; then
      actual="runner mismatch (CLI=$EVAL_RUNNER case=$case_runner)"
      case_results+=("$(_case_error_result "$cid" "CLI and case runner agree" "$actual" "runner selection conflict")")
      echo "[eval-harness] case $cid: $actual" >&2
      continue
    fi
    EFFECTIVE_RUNNER="$case_runner"
  elif [[ -n "${EVAL_RUNNER:-}" ]]; then
    EFFECTIVE_RUNNER="$EVAL_RUNNER"
  else
    EFFECTIVE_RUNNER="opencode"
  fi
  export EVAL_RUNNER="$EFFECTIVE_RUNNER"

  case "$EFFECTIVE_RUNNER" in
    opencode) ;;
    langgraph-node)
      if ! preflight_check_langgraph; then
        case_results+=("$(_case_error_result "$cid" "runner preflight succeeds" "preflight failed for runner=$EFFECTIVE_RUNNER" "runner-specific prerequisites unavailable")")
        continue
      fi
      ;;
    *)
      case_results+=("$(_case_error_result "$cid" "supported runner" "unknown runner '$EFFECTIVE_RUNNER'" "runner adapter is not registered")")
      continue
      ;;
  esac

  eval_type="$(yq -r '.eval_type // "regression"' "$case_file" 2>/dev/null || echo regression)"
  compare_to_baseline="$(yq -r '.compare_to_baseline // false' "$case_file" 2>/dev/null || echo false)"
  if [[ "$eval_type" == "regression" ]]; then compare_to_baseline=true; fi
  case "$compare_to_baseline" in true|false) ;; *) compare_to_baseline=false ;; esac
  # (#21) Stochastic mode runs the case samples times; the stability resampler below is diagnostic only.
  case_mode="$(yq -r '.mode // "deterministic"' "$case_file" 2>/dev/null || echo deterministic)"
  # pass_threshold is a count gate; named pass@k/pass^k estimates remain separate.

  if [[ "$DRY_RUN" == "1" ]]; then
    echo "[eval-harness] [dry-run] case $i/${#CASE_FILES[@]} $cid runner=$EFFECTIVE_RUNNER"
    continue
  fi

  per_case_dir="$RUN_DIR/$cid"
  mkdir -p "$per_case_dir"
  cp "$case_file" "$per_case_dir/case.yaml"
  workdir="$per_case_dir/workdir"
  sandbox="$per_case_dir/sandbox"
  mkdir -p "$workdir"

  fixture_error=0
  while IFS=$'\t' read -r dest src; do
    # Strip trailing CR: on Windows, jq emits CRLF line endings, which
    # would otherwise end up inside the `src` variable and break
    # subsequent [[ -f ]] checks (Windows MSYS treats \r as a literal
    # filename character, not a control byte).
    dest="${dest%$'\r'}"
    src="${src%$'\r'}"
    [[ -z "$dest" ]] && continue

    if [[ "$dest" = /* ]] || [[ "$dest" == *..* ]]; then
      echo "[eval-harness] case $cid: rejecting fixture dest='$dest' (absolute or contains '..')" >&2
      fixture_error=1
      break
    fi

    src_path="$src"
    if [[ "$src" != /* ]]; then
      src_path="$EVALS_DIR/$src"
    fi

    full_dest="$workdir/$dest"
    # Normalize via python (handles ./, ../, redundant slashes) but then
    # convert any backslashes to forward slashes so bash's pattern
    # matching works the same on Windows and POSIX. On POSIX, paths
    # already use forward slashes and the substitution is a no-op.
    canonical_dest="$(python3 -c "import os,sys; print(os.path.normpath(sys.argv[1]).replace(os.sep, '/'))" "$full_dest")"
    canonical_workdir="$(python3 -c "import os,sys; print(os.path.normpath(sys.argv[1]).replace(os.sep, '/'))" "$workdir")"
    if [[ "$canonical_dest" != "$canonical_workdir"/* && "$canonical_dest" != "$canonical_workdir" ]]; then
      echo "[eval-harness] case $cid: rejecting fixture dest='$dest' — resolves outside workdir" >&2
      fixture_error=1
      break
    fi

    if ! mkdir -p "$(dirname "$full_dest")"; then
      echo "[eval-harness] case $cid: mkdir failed for $(dirname "$full_dest")" >&2
      fixture_error=1
      break
    fi
    if [[ -f "$src_path" ]]; then
      if ! cp "$src_path" "$full_dest"; then
        echo "[eval-harness] case $cid: cp failed: $src_path -> $full_dest" >&2
        fixture_error=1
        break
      fi
    else
      echo "[eval-harness] case $cid: fixture source missing: $src_path" >&2
      fixture_error=1
      break
    fi
  done < <(yq -o=json '.setup.fixtures // {}' "$case_file" | jq -r 'to_entries[] | "\(.key)\t\(.value)"')

  if [[ "$fixture_error" == "1" ]]; then
    echo "[eval-harness] case $cid: fixture errors — case marked ERROR" >&2
    case_results+=("$(_case_error_result "$cid" "valid in-workdir fixtures" "fixture setup failed" "case fixtures were rejected, missing, or could not be copied")")
    continue
  fi

  export EVAL_FIXTURE_DIR="$FIXTURES_DIR"
  transcript="$per_case_dir/transcript.jsonl"

  lock_dir="$STATE_DIR/locks"
  mkdir -p "$lock_dir"
  lock_key="$(printf '%s' "$SKILL:$cid:$TRIGGER" | tr '/ ' '__')"
  lock_file="$lock_dir/$lock_key.lock"
  lock_timeout="${EVAL_LOCK_TIMEOUT:-300}"

  exec 9>"$lock_file"
  if command -v flock >/dev/null 2>&1; then
    if ! flock -w "$lock_timeout" -x 9; then
      echo "[eval-harness] lock timeout (${lock_timeout}s) on $SKILL:$cid:$TRIGGER — another run holds it" >&2
      exec 9>&-
      case_results+=("$(_case_error_result "$cid" "case lock acquired" "timeout ${lock_timeout}s" "another evaluation run held the case lock")")
      continue
    fi
  else
    mkdir_lock="${lock_file}.d"
    waited=0
    while ! mkdir "$mkdir_lock" 2>/dev/null; do
      if [[ "$waited" -ge "$lock_timeout" ]]; then
        echo "[eval-harness] mkdir-lock timeout (${lock_timeout}s) on $SKILL:$cid:$TRIGGER" >&2
        exec 9>&-
        case_results+=("$(_case_error_result "$cid" "case lock acquired" "timeout ${lock_timeout}s" "another evaluation run held the mkdir lock")")
        continue 2
      fi
      sleep 1
      waited=$((waited+1))
    done
  fi

  export EVAL_CASE_FILE="$per_case_dir/case.yaml"
  tool_manifest_rel="$(yq -r '.tool_manifest_file // ""' "$case_file" 2>/dev/null || echo "")"
  if [[ -n "$tool_manifest_rel" ]]; then EVAL_TOOL_MANIFEST_FILE="$workdir/$tool_manifest_rel"; export EVAL_TOOL_MANIFEST_FILE; else unset EVAL_TOOL_MANIFEST_FILE; fi
  runner_config_json="$(yq -o=json '.runner_config // {}' "$case_file" 2>/dev/null || echo '{}')"
  EVAL_RUNNER_CONFIG_SHA="$(printf '%s' "$runner_config_json" | portable_sha256_stdin | awk '{print $1}')"
  EVAL_GRAPH_FINGERPRINT="none"
  if [[ "$EFFECTIVE_RUNNER" == "langgraph-node" ]]; then
    EVAL_GRAPH_FINGERPRINT="$(dispatch_runner fingerprint "$EFFECTIVE_RUNNER" "$workdir" "$runner_config_json" 2>/dev/null || echo none)"
    [[ -n "$EVAL_GRAPH_FINGERPRINT" ]] || EVAL_GRAPH_FINGERPRINT="none"
  fi
  export EVAL_RUNNER_CONFIG_SHA EVAL_GRAPH_FINGERPRINT
  capture_manifest "$SKILL" "$per_case_dir/env-manifest.json"


  if [[ "$case_mode" == "stochastic" ]]; then
    st_samples="$(yq -r '.samples // 5' "$case_file" 2>/dev/null || echo 5)"
    st_threshold="$(yq -r '.pass_threshold // 0' "$case_file" 2>/dev/null || echo 0)"
    st_temp="$(yq -r '.temperature // 0' "$case_file" 2>/dev/null || echo 0)"
    st_pass_k="$(yq -r '.pass_k // ""' "$case_file" 2>/dev/null || echo "")"
    st_ci_gate="$(yq -r '.ci_gate // ""' "$case_file" 2>/dev/null || echo "")"
    st_required="$(yq -r '.ci_required_rate // ""' "$case_file" 2>/dev/null || echo "")"
    st_rg_metric="$(yq -r '.reliability_gate.metric // ""' "$case_file" 2>/dev/null || echo "")"
    st_rg_min="$(yq -r '.reliability_gate.minimum // ""' "$case_file" 2>/dev/null || echo "")"
    st_rg_confidence="$(yq -r '.reliability_gate.confidence // "lower"' "$case_file" 2>/dev/null || echo lower)"
    st_z="$(printenv EVAL_WILSON_Z 2>/dev/null || echo 1.96)"
    st_config_error=""
    if [[ "$eval_type" != "capability" && "$eval_type" != "regression" && "$eval_type" != "product" ]]; then st_config_error="eval_type must be capability, regression, or product"; fi
    if ! [[ "$st_samples" =~ ^[1-9][0-9]*$ ]] || ! [[ "$st_threshold" =~ ^[0-9]+$ ]]; then st_config_error="samples and pass_threshold must be integers; samples must be positive"; fi
    if [[ -z "$st_config_error" ]]; then
      if [[ -z "$st_pass_k" ]]; then if [[ "$st_samples" -ge 3 ]]; then st_pass_k=3; else st_pass_k="$st_samples"; fi; fi
      if ! [[ "$st_pass_k" =~ ^[1-9][0-9]*$ ]] || [[ "$st_pass_k" -gt "$st_samples" ]]; then st_config_error="pass_k must be an integer in [1,samples]"; fi
      if [[ "$st_threshold" -eq 0 ]]; then st_threshold="$st_samples"; fi
      if [[ "$st_threshold" -gt "$st_samples" ]]; then st_config_error="pass_threshold cannot exceed samples"; fi
    fi
    if [[ "$st_ci_gate" != "" && "$st_ci_gate" != "lower_bound" ]]; then st_config_error="ci_gate must be lower_bound or unset"; fi
    if [[ "$st_ci_gate" == "lower_bound" ]] && { ! [[ "$st_required" =~ ^(0([.][0-9]+)?|1([.]0+)?)$ ]]; }; then st_config_error="ci_required_rate must be a number in [0,1]"; fi
    if [[ "$st_rg_metric" != "" && "$st_rg_metric" != "pass_at_k" && "$st_rg_metric" != "pass_power_k" ]]; then st_config_error="reliability_gate.metric must be pass_at_k or pass_power_k"; fi
    if [[ "$st_rg_metric" != "" ]] && { ! [[ "$st_rg_min" =~ ^(0([.][0-9]+)?|1([.]0+)?)$ ]] || [[ "$st_rg_confidence" != "lower" ]]; }; then st_config_error="reliability_gate requires minimum in [0,1] and confidence: lower"; fi
    if ! [[ "$st_z" =~ ^[0-9]+([.][0-9]+)?$ ]] || ! awk -v z="$st_z" 'BEGIN{exit !(z>0)}'; then st_config_error="EVAL_WILSON_Z must be positive"; fi
    if [[ -n "$st_config_error" ]]; then
      jq -n --arg cid "$cid" --arg err "$st_config_error" --arg et "$eval_type" --argjson cmp "$compare_to_baseline" '{
        passed:false,status:"ERROR",evaluation_type:$et,compare_to_baseline:$cmp,total:1,pass_count:0,fail_count:1,
        checks:[{kind:"harness_error",passed:false,status:"ERROR",error:true,failed_check_id:("stochastic_misconfig:"+$cid),
          expected:"valid stochastic sampling and reliability configuration",actual:$err,diff_hint:$err}],quality:{dimensions:{},aggregate:null}
      }' > "$per_case_dir/checks.json"
      st_samples=0
    fi
    [[ "$st_temp" =~ ^[0-9]+(\.[0-9]+)?$ ]] || st_temp=0
    st_pass=0; st_unknown=0; st_valid=0
    [[ "$st_samples" -gt 0 ]] && : > "$transcript"
    echo "[eval-harness] case $cid: stochastic mode — $st_samples samples, threshold $st_threshold, k=$st_pass_k, temp $st_temp" >&2
    s=1
    while [[ "$s" -le "$st_samples" ]]; do
      st_sd="$per_case_dir/stochastic/sample-$s"
      mkdir -p "$st_sd/workdir"
      cp -R "$workdir/." "$st_sd/workdir/" 2>/dev/null || true
      st_tr="$st_sd/transcript.jsonl"
      sample_exit_code=0
      if [[ "$EFFECTIVE_RUNNER" == "opencode" ]] && ! command -v opencode >/dev/null 2>&1; then
        echo "[eval-harness] WARNING: opencode CLI not on PATH — emitting stub transcript for offline scoring" >&2
        : > "$st_tr"
      else
        sample_exit_code="$(EVAL_TEMPERATURE="$st_temp" _spawn_case_runner "$prompt" "$st_sd/workdir" "$st_sd/sandbox" "$st_tr" "${skills_loaded[@]}")"
      fi
      if [[ "$sample_exit_code" == "124" || ( "$sample_exit_code" != "0" && ! -s "$st_tr" ) ]]; then
        jq -n --arg cid "$cid" --arg code "$sample_exit_code" --arg runner "$EFFECTIVE_RUNNER" --arg et "$eval_type" --argjson cmp "$compare_to_baseline" '{
          passed:false,status:"ERROR",evaluation_type:$et,compare_to_baseline:$cmp,total:0,pass_count:0,fail_count:1,
          checks:[{kind:"harness_error",passed:false,status:"ERROR",error:true,failed_check_id:("sample_spawn:"+$cid),expected:($runner+" completes with sample evidence"),actual:($runner+" exit "+$code),diff_hint:"sample runner failed before producing evidence"}],quality:{dimensions:{},aggregate:null}
        }' > "$st_sd/checks.json"
      else
        run_all_checks "$case_file" "$st_sd/workdir" "$st_tr" "$st_sd/checks.json"
      fi
      sample_status="$(jq -r '.status // (if .passed==true then "PASS" else "FAIL" end)' "$st_sd/checks.json" 2>/dev/null || echo ERROR)"
      case "$sample_status" in
        PASS) st_pass=$((st_pass+1)); st_valid=$((st_valid+1)) ;;
        FAIL) st_valid=$((st_valid+1)) ;;
        *) st_unknown=$((st_unknown+1)) ;;
      esac
      cat "$st_tr" >> "$transcript" 2>/dev/null || true
      s=$((s+1))
    done
    if [[ "$st_samples" -gt 0 ]]; then
      st_overall=false; st_status="FAIL"
      if [[ "$st_unknown" -eq 0 ]]; then
        st_reliability="$(reliability_metrics "$st_pass" "$st_samples" "$st_pass_k" "$st_z")"
        st_wilson="$(printf '%s' "$st_reliability" | jq -c '.wilson')"
        [[ "$st_pass" -ge "$st_threshold" ]] && st_overall=true
        if [[ "$st_ci_gate" == "lower_bound" ]]; then
          _wl="$(printf '%s' "$st_wilson" | jq -r '.lower')"
          if ! awk -v a="$_wl" -v b="$st_required" 'BEGIN{exit !(a+0 >= b+0)}'; then st_overall=false; fi
        fi
        if [[ "$st_rg_metric" == "pass_at_k" ]]; then _rg_lower="$(printf '%s' "$st_reliability" | jq -r '.pass_at_k_interval.lower')"; fi
        if [[ "$st_rg_metric" == "pass_power_k" ]]; then _rg_lower="$(printf '%s' "$st_reliability" | jq -r '.pass_power_k_interval.lower')"; fi
        if [[ -n "$st_rg_metric" ]] && ! awk -v a="$_rg_lower" -v b="$st_rg_min" 'BEGIN{exit !(a+0 >= b+0)}'; then st_overall=false; fi
        [[ "$st_overall" == "true" ]] && st_status="PASS"
      else
        st_status="INDETERMINATE"
        st_reliability="$(jq -n --argjson n "$st_samples" --argjson x "$st_pass" --argjson k "$st_pass_k" '{status:"unavailable",successes:$x,attempts:$n,k:$k,success_rate:null,pass_at_k:null,pass_power_k:null,reason:"one or more trial outcomes were pending, unavailable, or erroneous"}')"
        st_wilson="$(wilson_interval 0 0 "$st_z")"
        st_overall=false
      fi
      jq -n --argjson passed "$st_overall" --arg status "$st_status" --argjson sc "$st_samples" --argjson valid "$st_valid" \
        --argjson unknown "$st_unknown" --argjson pc "$st_pass" --argjson th "$st_threshold" --argjson k "$st_pass_k" \
        --arg temp "$st_temp" --arg cid "$cid" --arg et "$eval_type" --argjson cmp "$compare_to_baseline" \
        --argjson wilson "$st_wilson" --argjson reliability "$st_reliability" \
        --arg ci_gate "$st_ci_gate" --arg req "$st_required" --arg rg_metric "$st_rg_metric" --arg rg_min "$st_rg_min" '{
          passed:$passed,status:$status,evaluation_type:$et,compare_to_baseline:$cmp,total:1,
          pass_count:(if $passed then 1 else 0 end),fail_count:(if $passed then 0 else 1 end),needs_review:($status=="NEEDS_REVIEW"),indeterminate:($status=="INDETERMINATE"),
          stochastic:{mode:"stochastic",samples:$sc,valid_samples:$valid,unavailable_samples:$unknown,sample_pass_count:$pc,pass_threshold:$th,pass_k:$k,temperature:$temp,wilson:$wilson,
            ci_gate:(if $ci_gate=="" then null else {metric:"success_rate",minimum:($req|tonumber? // null)} end),
            reliability_gate:(if $rg_metric=="" then null else {metric:$rg_metric,minimum:($rg_min|tonumber? // null),confidence:"lower"} end)},
          reliability:$reliability,quality:{dimensions:{},aggregate:null},
          checks:[{kind:"stochastic",passed:$passed,status:$status,required:true,score:(if $passed then 1 else 0 end),dimension:"reliability",weight:1,
            failed_check_id:("stochastic:"+$cid),expected:(if $rg_metric!="" then ($rg_metric+" lower confidence bound >= "+$rg_min) elif $ci_gate=="lower_bound" then ("Wilson lower bound >= "+$req) else ("at least "+($th|tostring)+" of "+($sc|tostring)+" samples pass") end),
            actual:(($pc|tostring)+"/"+($sc|tostring)+" samples passed; success_rate="+($reliability.success_rate|tostring)+" pass@k="+($reliability.pass_at_k|tostring)+" pass^k="+($reliability.pass_power_k|tostring)),
            diff_hint:(if $passed then "" else "stochastic or reliability gate not met" end)}]
        }' > "$per_case_dir/checks.json"
    fi
    exit_code=0
  else
    if [[ "$EFFECTIVE_RUNNER" == "opencode" ]] && ! command -v opencode >/dev/null 2>&1; then
      echo "[eval-harness] WARNING: opencode CLI not on PATH — emitting stub transcript for offline scoring" >&2
      : > "$transcript"
      exit_code=0
    else
      exit_code="$( _spawn_case_runner "$prompt" "$workdir" "$sandbox" "$transcript" "${skills_loaded[@]}" )"
    fi
    if [[ "$exit_code" == "124" ]]; then
      max_seconds="$(printenv EVAL_MAX_SECONDS 2>/dev/null || echo 180)"
      echo "[eval-harness] case $cid: runner=$EFFECTIVE_RUNNER timed out after $max_seconds (exit 124)" >&2
      jq -n --arg cid "$cid" --arg runner "$EFFECTIVE_RUNNER" --arg seconds "$max_seconds" --arg et "$eval_type" --argjson cmp "$compare_to_baseline" '{
        passed:false,status:"ERROR",evaluation_type:$et,compare_to_baseline:$cmp,total:0,pass_count:0,fail_count:1,
        checks:[{kind:"harness_error",passed:false,status:"ERROR",error:true,failed_check_id:("timeout:"+$cid),expected:($runner+" completes within "+$seconds),actual:"timeout (exit 124)",diff_hint:($runner+" was killed by timeout") }],quality:{dimensions:{},aggregate:null}
      }' > "$per_case_dir/checks.json"
    elif [[ "$exit_code" != "0" ]] && [[ ! -s "$transcript" ]]; then
      echo "[eval-harness] case $cid: runner=$EFFECTIVE_RUNNER exited $exit_code with empty transcript" >&2
      jq -n --arg cid "$cid" --arg runner "$EFFECTIVE_RUNNER" --arg actual "exit $exit_code, empty transcript" --arg et "$eval_type" --argjson cmp "$compare_to_baseline" '{
        passed:false,status:"ERROR",evaluation_type:$et,compare_to_baseline:$cmp,total:0,pass_count:0,fail_count:1,
        checks:[{kind:"harness_error",passed:false,status:"ERROR",error:true,failed_check_id:("spawn_failed:"+$cid),expected:($runner+" produces transcript"),actual:$actual,diff_hint:($runner+" exited non-zero and wrote nothing")}],quality:{dimensions:{},aggregate:null}
      }' > "$per_case_dir/checks.json"
    else
      run_all_checks "$case_file" "$workdir" "$transcript" "$per_case_dir/checks.json"
    fi
  fi
  jq --arg et "$eval_type" --argjson cmp "$compare_to_baseline" '. + {evaluation_type:(.evaluation_type // $et),compare_to_baseline:(if has("compare_to_baseline") then .compare_to_baseline else $cmp end)}' "$per_case_dir/checks.json" > "$per_case_dir/checks.json.tmp" && mv "$per_case_dir/checks.json.tmp" "$per_case_dir/checks.json"
  primary_passed="$(jq -r '.passed' "$per_case_dir/checks.json" 2>/dev/null || echo false)"
  stability_json='{"samples":1,"byte_identical":true,"hashes":[],"performed":false}'
  if [[ "$STABILITY_SAMPLES" -gt 1 && "$primary_passed" == "false" ]]; then
    echo "[eval-harness] case $cid FAILed — running $((STABILITY_SAMPLES - 1)) stability sample(s)" >&2
    hashes=("$(hash_checks "$per_case_dir/checks.json")")
    s=2
    while [[ "$s" -le "$STABILITY_SAMPLES" ]]; do
      sample_dir="$per_case_dir/stability/sample-$s"
      mkdir -p "$sample_dir"
      sample_workdir="$sample_dir/workdir"
      sample_sandbox="$sample_dir/sandbox"
      cp -R "$workdir" "$sample_workdir"
      sample_transcript="$sample_dir/transcript.jsonl"
      case "$EFFECTIVE_RUNNER" in
        opencode)
          if command -v opencode >/dev/null 2>&1; then
            spawn_runner opencode "$prompt" "$sample_workdir" "$sample_sandbox" "$sample_transcript" "${skills_loaded[@]}" >/dev/null
          else
            : > "$sample_transcript"
          fi
          ;;
        langgraph-node)
          input_file="$(yq -r '.runner_config.input // "input.json"' "$case_file" 2>/dev/null || echo "input.json")"
          output_file="$(yq -r '.runner_config.output // "output.json"' "$case_file" 2>/dev/null || echo "output.json")"
          runner_config_json="$(yq -o=json '.runner_config // {}' "$case_file" 2>/dev/null || echo '{}')"
          spawn_runner langgraph-node "$sample_workdir" "$sample_workdir/$input_file" "$sample_workdir/$output_file" "$sample_transcript" "$runner_config_json" >/dev/null
          ;;
      esac
      run_all_checks "$case_file" "$sample_workdir" "$sample_transcript" "$sample_dir/checks.json"
      hashes+=("$(hash_checks "$sample_dir/checks.json")")
      s=$((s+1))
    done
    first="${hashes[0]}"
    identical="true"
    for h in "${hashes[@]}"; do
      [[ "$h" != "$first" ]] && { identical="false"; break; }
    done
    hashes_json="$(printf '%s\n' "${hashes[@]}" | jq -R . | jq -s .)"
    stability_json="$(jq -n \
      --argjson samples "$STABILITY_SAMPLES" \
      --argjson identical "$identical" \
      --argjson hashes "$hashes_json" \
      '{samples:$samples, byte_identical:$identical, hashes:$hashes, performed:true}')"
    if [[ "$identical" == "false" ]]; then
      echo "[eval-harness] case $cid is FLAKY (samples diverged) — attribution will be tagged" >&2
    fi
  fi
  echo "$stability_json" > "$per_case_dir/stability.json"
  write_case_grading_manifest "$per_case_dir/case.yaml" "$workdir" "$transcript" "$per_case_dir/env-manifest.json" "$RUN_ID" "$cid" "$per_case_dir/grading-manifest.json"

  if ! command -v flock >/dev/null 2>&1; then
    rmdir "${lock_file}.d" 2>/dev/null || true
  fi
  exec 9>&-

  baseline_path="$BASELINES_DIR/$cid.baseline.json"
  case_result="$(SKILL_UNDER_TEST="$SKILL" build_case_result "$cid" "$per_case_dir" "$baseline_path")"
  # (#EV-P) Additive per-case wall-clock; warn (never fail) if over EVAL_STEP_BUDGET_MS.
  _case_dur_ms=$(( $(_now_ms) - _case_start_ms ))
  case_result="$(printf '%s' "$case_result" | jq --argjson d "$_case_dur_ms" '. + {duration_ms:$d} | .resources.duration_ms={status:"measured",value_ms:$d}')"
  perf_warn_if_slow "case:$cid" "$_case_dur_ms"
  case_results+=("$case_result")

  case_status="$(printf '%s' "$case_result" | jq -r '.status // (if .passed then "PASS" else "FAIL" end)')"
  echo "[eval-harness] Case $i/${#CASE_FILES[@]} $cid $case_status"
done

if [[ "$DRY_RUN" == "1" ]]; then
  echo "[eval-harness] dry-run complete"
  exit 0
fi

results_array_json="$(printf '%s\n' "${case_results[@]}" | jq -s .)"
summary_json="$(build_run_summary "$results_array_json" "$RUN_ID" "$TRIGGER" "${MAX_REGRESSIONS:--1}")"
echo "$summary_json" > "$RUN_DIR/results.json"
# Run duration is an informational field in results schema 3.
_run_dur_ms=$(( $(_now_ms) - _RUN_START_MS ))
_rj_tmp="$RUN_DIR/results.json.tmp.$$"
jq --argjson d "$_run_dur_ms" '.summary.duration_ms = $d' "$RUN_DIR/results.json" > "$_rj_tmp" && mv "$_rj_tmp" "$RUN_DIR/results.json"
perf_warn_if_slow "run:$RUN_ID" "$_run_dur_ms"
render_diff_md "$RUN_DIR/results.json" "$RUN_DIR/diff.md"
if [[ -n "$REPORTS" ]]; then
  IFS=',' read -ra _report_specs <<< "$REPORTS"
  for spec in "${_report_specs[@]}"; do
    [[ -z "$spec" ]] && continue
    fmt="${spec%%:*}"; path="${spec#*:}"
    if [[ "$fmt" == "$spec" || -z "$path" ]]; then echo "[eval-harness] ignoring malformed --report spec '$spec' (expected fmt:path)" >&2; continue; fi
    mkdir -p "$(dirname "$path")" 2>/dev/null || true
    case "$fmt" in
      junit) render_junit "$RUN_DIR/results.json" > "$path" && echo "[eval-harness] wrote JUnit report: $path" ;;
      sarif) render_sarif "$RUN_DIR/results.json" "$VERSION" > "$path" && echo "[eval-harness] wrote SARIF report: $path" ;;
      *) echo "[eval-harness] unknown report format '$fmt' (junit|sarif)" >&2 ;;
    esac
  done
fi
append_history_line "$(jq -c --arg event run --arg skill "$SKILL" --arg ts "$(date -u +%FT%TZ)" '{event:$event,timestamp:$ts,run_id:.run_id,skill:$skill,trigger:.trigger,verdict:.verdict,summary:.summary}' "$RUN_DIR/results.json")"
run_cost_usd="$(jq -r 'if (.summary.total_cost_usd|type)=="number" then .summary.total_cost_usd else "null" end' "$RUN_DIR/results.json")"
budget_append "$RUN_ID" "$run_cost_usd" "${EVAL_MODEL:-unknown}"
budget_postcheck || true

verdict="$(jq -r '.verdict' "$RUN_DIR/results.json")"
pass="$(jq -r '.summary.pass' "$RUN_DIR/results.json")"
total="$(jq -r '.summary.total' "$RUN_DIR/results.json")"
regressions="$(jq -r '.regressions | join(", ")' "$RUN_DIR/results.json")"

case "$verdict" in
  PASS)
    echo "[eval-harness] PASS $pass/$total — see $RUN_DIR/diff.md"
    exit 0 ;;
  REGRESSION)
    echo "[eval-harness] REGRESSION ($pass/$total) — regressions: $regressions"
    echo "[eval-harness] see $RUN_DIR/diff.md"
    if [[ "$(jq -r '.gate.regression_threshold_exceeded // false' "$RUN_DIR/results.json")" == "true" ]]; then
      echo "[eval-harness] configured --max-regressions threshold exceeded" >&2
      exit 12
    elif [[ "$STRICT" == "1" || -f "$STATE_DIR/promoted" ]]; then
      echo "[eval-harness] EVAL_HARNESS_REGRESSION=1" >&2
      exit 12
    else
      echo "[eval-harness] WARN-ONLY MODE: regression recorded; use --strict or promote to block." >&2
      exit 0
    fi ;;
  FAIL)
    echo "[eval-harness] FAIL ($pass/$total) — evaluation requirement failed"
    echo "[eval-harness] see $RUN_DIR/diff.md"
    if [[ "$STRICT" == "1" ]]; then exit 14; fi
    echo "[eval-harness] WARN-ONLY MODE: non-regression failure recorded." >&2
    exit 0 ;;
  NEEDS_REVIEW)
    echo "[eval-harness] NEEDS_REVIEW ($pass/$total) — a required human review is pending"
    if [[ "$STRICT" == "1" ]]; then exit 15; fi
    echo "[eval-harness] WARN-ONLY MODE: review pending." >&2
    exit 0 ;;
  INDETERMINATE)
    echo "[eval-harness] INDETERMINATE ($pass/$total) — required evidence unavailable"
    if [[ "$STRICT" == "1" ]]; then exit 16; fi
    echo "[eval-harness] WARN-ONLY MODE: result is indeterminate." >&2
    exit 0 ;;
  ERROR)
    echo "[eval-harness] ERROR: harness/scorer execution failed" >&2
    exit 13 ;;
  *)
    echo "[eval-harness] ERROR: unknown verdict '$verdict'" >&2
    exit 13 ;;
esac
