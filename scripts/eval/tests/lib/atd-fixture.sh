#!/usr/bin/env bash
# Shared helpers for discovery grader/report tests (NOT a test: lives in tests/lib so scripts/eval/test.sh skips it).
# Evidence is produced by the real attest.mjs signer into a disposable EVAL_STATE_DIR and graded by the real
# score.sh / grading_manifest.sh / diff.sh / grade.sh code paths in the same sequence run.sh uses.

FX_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FX_EVAL_DIR="$(cd "$FX_LIB_DIR/../.." && pwd)"
FX_RUN_ID="run-fx"

fx_init() {
  FX_TMP="$(mktemp -d -t atd-fx.XXXXXX)"
  export EVAL_STATE_DIR="$FX_TMP/state"
  mkdir -p "$EVAL_STATE_DIR" "$FX_TMP/runs/$FX_RUN_ID"
  export SKILL_UNDER_TEST=fx-skill
  # shellcheck source=/dev/null
  source "$FX_EVAL_DIR/lib/yq-shim.sh"
  source "$FX_EVAL_DIR/lib/score.sh"
  source "$FX_EVAL_DIR/lib/diff.sh"
  source "$FX_EVAL_DIR/lib/grading_manifest.sh"
  source "$FX_EVAL_DIR/lib/stability.sh"
  source "$FX_EVAL_DIR/lib/report_junit.sh"
  source "$FX_EVAL_DIR/lib/report_sarif.sh"
}

fx_fail() { echo "FAIL: $*" >&2; exit 1; }

# fx_eq <actual> <expected> <message>
fx_eq() { [[ "$1" == "$2" ]] || fx_fail "$3 (expected '$2', got '$1')"; }
# fx_build <workdir> [fixture options...] — signed evidence in <workdir>/atd-out (fresh execution ids every call).
# Run/case ids default to the harness run id and the case dir name (samples resolve to their parent case).
fx_build() {
  local wd="$1"; shift
  local d cid
  mkdir -p "$wd"
  d="$(cd "$wd/.." && pwd)"
  if [[ "$(basename "$(dirname "$d")")" == stability ]]; then cid="$(basename "$(dirname "$(dirname "$d")")")"; else cid="$(basename "$d")"; fi
  node "$FX_LIB_DIR/atd-fixture.mjs" build --workdir="$wd" --run-id="$FX_RUN_ID" --case-id="$cid" "$@" >/dev/null || fx_fail "fixture build failed: $*"
  printf '%s\n' "$@" > "$d/.fx-args"
}

# fx_jq <json> <filter>
fx_jq() { printf '%s' "$1" | jq -r "$2"; }

# fx_case <id> [extra check yaml] -> case dir; checks default to required discovery_finding + optional health
fx_case() {
  local id="$1" extra="${2:-}" cd
  cd="$FX_TMP/runs/$FX_RUN_ID/$id"
  mkdir -p "$cd/workdir"
  cat > "$cd/case.yaml" <<YAML
schema_version: 2
id: $id
eval_type: capability
runner: atd-sandbox
prompt: discovery
checks:
  - kind: discovery_finding
    required: true
    severity: high
  - kind: discovery_test_health
    required: false
$extra
YAML
  printf '{"schema_version":4,"model_id":"test/model","runner":"atd-sandbox"}\n' > "$cd/env-manifest.json"
  : > "$cd/transcript.jsonl"
  printf '%s' "$cd"
}

# fx_pipeline <case_dir> <samples> [sample override strings | __copy__ ...]
# Mirrors run.sh: grade primary, on non-PASS re-run (fresh signed evidence per sample), hash, write stability.json,
# write grading manifest. Each sample override string is appended to the primary fixture options.
fx_pipeline() {
  local cd="$1" samples="$2"; shift 2
  local cid; cid="$(basename "$cd")"
  local -a sargs=("$@") primary=() hashes=()
  local line s sd sarg h first identical hashes_json
  while IFS= read -r line; do primary+=("$line"); done < "$cd/.fx-args"
  export EVAL_RUN_ID="$FX_RUN_ID" EVAL_CASE_ID="$cid"
  run_all_checks "$cd/case.yaml" "$cd/workdir" "$cd/transcript.jsonl" "$cd/checks.json"
  jq '. + {evaluation_type:(.evaluation_type // "capability"),compare_to_baseline:(.compare_to_baseline // false)}' "$cd/checks.json" > "$cd/checks.json.tmp" && mv "$cd/checks.json.tmp" "$cd/checks.json"
  local primary_passed; primary_passed="$(jq -r '.passed' "$cd/checks.json")"
  local stability='{"samples":1,"byte_identical":true,"hashes":[],"performed":false}'
  if [[ "$samples" -gt 1 && "$primary_passed" == "false" ]]; then
    hashes+=("$(hash_checks "$cd/checks.json")")
    s=2
    while [[ "$s" -le "$samples" ]]; do
      sd="$cd/stability/sample-$s"
      mkdir -p "$sd"
      cp -R "$cd/workdir" "$sd/workdir"
      : > "$sd/transcript.jsonl"
      sarg="${sargs[$((s-2))]:-}"
      if [[ "$sarg" != "__copy__" ]]; then
        # shellcheck disable=SC2086
        fx_build "$sd/workdir" "${primary[@]}" $sarg
      fi
      run_all_checks "$cd/case.yaml" "$sd/workdir" "$sd/transcript.jsonl" "$sd/checks.json"
      hashes+=("$(hash_checks "$sd/checks.json")")
      s=$((s+1))
    done
    first="${hashes[0]}"; identical=true
    for h in "${hashes[@]}"; do [[ "$h" == "$first" ]] || { identical=false; break; }; done
    hashes_json="$(printf '%s\n' "${hashes[@]}" | jq -R . | jq -s .)"
    stability="$(jq -n --argjson samples "$samples" --argjson identical "$identical" --argjson hashes "$hashes_json" '{samples:$samples,byte_identical:$identical,hashes:$hashes,performed:true}')"
  fi
  echo "$stability" > "$cd/stability.json"
  write_case_grading_manifest "$cd/case.yaml" "$cd/workdir" "$cd/transcript.jsonl" "$cd/env-manifest.json" "$FX_RUN_ID" "$cid" "$cd/grading-manifest.json"
}

# fx_result <case_dir> -> build_case_result JSON (what run.sh puts in results.json cases[])
fx_result() {
  local cd="$1"
  build_case_result "$(basename "$cd")" "$cd" "$FX_TMP/no-baseline.json"
}

# fx_check <case_result_json> <kind> <jq field>
fx_check() { printf '%s' "$1" | jq -r --arg k "$2" "[.checks[] | select(.kind==\$k)][0] | $3"; }
