#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$SCRIPT_DIR/lib/score.sh"
source "$SCRIPT_DIR/lib/diff.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

expect_status() {
  local id="$1" expected="$2" actual
  run_all_checks "$TMP/cases/$id.yaml" "$TMP/$id/workdir" "$TMP/$id/transcript.jsonl" "$TMP/$id/result.json"
  actual="$(jq -r '.status' "$TMP/$id/result.json")"
  if [[ "$actual" != "$expected" ]]; then
    echo "FAIL $id expected=$expected actual=$actual" >&2
    cat "$TMP/$id/result.json" >&2
    exit 1
  fi
  echo "PASS $id -> $actual"
}

mkdir -p "$TMP/cases"
for id in basic metric-pass metric-fail metric-missing human-pending human-pass trajectory-pass trajectory-fail transcript-unavailable no-required; do
  mkdir -p "$TMP/$id/workdir"
  : > "$TMP/$id/transcript.jsonl"
done
printf 'mesh\n' > "$TMP/basic/workdir/mesh.glb"
cat > "$TMP/cases/basic.yaml" <<'YAML'
schema_version: 2
id: basic
eval_type: capability
checks:
  - kind: file_exists
    path: mesh.glb
YAML

printf '{"quality":{"mesh":0.95}}\n' > "$TMP/metric-pass/workdir/metrics.json"
cat > "$TMP/cases/metric-pass.yaml" <<'YAML'
schema_version: 2
id: metric-pass
eval_type: product
checks:
  - kind: metric_score
    file: metrics.json
    path: $.quality.mesh
    minimum: 0.8
    dimension: geometry
    weight: 2
YAML
printf '{"quality":{"mesh":0.5}}\n' > "$TMP/metric-fail/workdir/metrics.json"
cat > "$TMP/cases/metric-fail.yaml" <<'YAML'
schema_version: 2
id: metric-fail
eval_type: product
compare_to_baseline: false
checks:
  - kind: metric_score
    file: metrics.json
    path: $.quality.mesh
    minimum: 0.8
    dimension: geometry
YAML
cat > "$TMP/cases/metric-missing.yaml" <<'YAML'
schema_version: 2
id: metric-missing
eval_type: product
checks:
  - kind: metric_score
    file: absent.json
    path: $.quality.mesh
    minimum: 0.8
    dimension: geometry
YAML
cat > "$TMP/cases/human-pending.yaml" <<'YAML'
schema_version: 2
id: human-pending
eval_type: product
checks:
  - kind: human_review
    review_file: review.json
    dimension: human_quality
YAML
cat > "$TMP/human-pass/workdir/review.json" <<'JSON'
{"schema_version":1,"status":"submitted","verdict":"PASS","reviewer":"reviewer-1","rubric_version":"r1","timestamp":"2026-01-01T00:00:00Z","rationale":"evidence checked"}
JSON
cat > "$TMP/cases/human-pass.yaml" <<'YAML'
schema_version: 2
id: human-pass
eval_type: product
checks:
  - kind: human_review
    review_file: review.json
    dimension: human_quality
YAML
cat > "$TMP/trajectory-pass/workdir/trajectory.jsonl" <<'JSONL'
{"seq":1,"type":"tool_call","tool":"inspect"}
{"seq":2,"type":"verification","id":"v1","status":"fail"}
{"seq":3,"type":"repair","repair_of":"v1","improved":true}
{"seq":4,"type":"verification","id":"v2","repair_of":"v1","status":"pass"}
JSONL
cat > "$TMP/cases/trajectory-pass.yaml" <<'YAML'
schema_version: 2
id: trajectory-pass
eval_type: capability
checks:
  - kind: trajectory
    file: trajectory.jsonl
    required_events: [tool_call, verification, repair]
    allowed_tools: [inspect]
    require_verification: true
    require_successful_repair: true
YAML
cat > "$TMP/trajectory-fail/workdir/trajectory.jsonl" <<'JSONL'
{"seq":1,"type":"tool_call","tool":"shell"}
JSONL
cat > "$TMP/cases/trajectory-fail.yaml" <<'YAML'
schema_version: 2
id: trajectory-fail
eval_type: capability
checks:
  - kind: trajectory
    file: trajectory.jsonl
    forbidden_tools: [shell]
YAML
cat > "$TMP/cases/transcript-unavailable.yaml" <<'YAML'
schema_version: 2
id: transcript-unavailable
eval_type: capability
checks:
  - kind: output_contains
    value: observed
YAML
cat > "$TMP/cases/no-required.yaml" <<'YAML'
schema_version: 2
id: no-required
eval_type: capability
checks:
  - kind: file_exists
    path: absent.file
    required: false
YAML

expect_status basic PASS
expect_status metric-pass PASS
[[ "$(jq -r '.quality.dimensions.geometry.score' "$TMP/metric-pass/result.json")" == "0.95" ]]
expect_status metric-fail FAIL
expect_status metric-missing INDETERMINATE
expect_status human-pending NEEDS_REVIEW
expect_status human-pass PASS
expect_status trajectory-pass PASS
expect_status trajectory-fail FAIL
export EVAL_TRANSCRIPT_UNAVAILABLE=1
expect_status transcript-unavailable INDETERMINATE
unset EVAL_TRANSCRIPT_UNAVAILABLE
expect_status no-required ERROR

# A product failure without explicit baseline comparison is not a regression and has unknown cost.
result_dir="$TMP/result-case"
mkdir -p "$result_dir"
cp "$TMP/metric-fail/result.json" "$result_dir/checks.json"
printf '{"schema_version":4,"model_id":"test/model","opencode_version":"test","skill_sha":"s","skill_bundle_sha":"b","fixture_sha":"f","per_skill_sha":{},"platform":"test","node_version":"test"}\n' > "$result_dir/env-manifest.json"
cp "$TMP/metric-fail/transcript.jsonl" "$result_dir/transcript.jsonl"
printf '{"samples":1,"byte_identical":true,"hashes":[],"performed":false}\n' > "$result_dir/stability.json"
printf '{"schema_version":1}\n' > "$result_dir/grading-manifest.json"
case_result="$(build_case_result metric-fail "$result_dir" "$TMP/no-baseline")"
[[ "$(printf '%s' "$case_result" | jq -r '.status+":"+(.regression|tostring)+":"+(.baseline_passed|tostring)')" == "FAIL:false:null" ]]
summary="$(build_run_summary "[$case_result]" dogfood manual 0)"
[[ "$(printf '%s' "$summary" | jq -r '.verdict+":"+(.summary.total_cost_usd|tostring)+":"+.summary.resources.cost.status')" == "FAIL:null:unavailable" ]]

# An explicit PASS baseline flip is a regression only when compare_to_baseline is true.
jq '.compare_to_baseline=true' "$result_dir/checks.json" > "$result_dir/checks.json.tmp"
mv "$result_dir/checks.json.tmp" "$result_dir/checks.json"
printf '{"schema_version":3,"case_id":"metric-fail","passed":true,"env_manifest":{"model_id":"test/model","opencode_version":"test","skill_sha":"s","skill_bundle_sha":"b","fixture_sha":"f","per_skill_sha":{},"platform":"test","node_version":"test"}}\n' > "$TMP/pass.baseline.json"
regressed="$(build_case_result metric-fail "$result_dir" "$TMP/pass.baseline.json")"
[[ "$(printf '%s' "$regressed" | jq -r '.regression')" == "true" ]]
regression_summary="$(build_run_summary "[$regressed]" dogfood manual 0)"
[[ "$(printf '%s' "$regression_summary" | jq -r '.verdict+":"+(.summary.regression_count|tostring)')" == "REGRESSION:1" ]]
echo 'PASS typed baseline gate, summaries, and 10 dogfood cases'
