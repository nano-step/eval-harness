#!/usr/bin/env bash
# Tests weighted dimension results, external human decisions, and normalized trajectories.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
source "$REPO_ROOT/scripts/eval/lib/score.sh"

WORK="$(mktemp -d -t eval-harness-graders.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/workdir"
: > "$WORK/transcript.jsonl"
printf '%s\n' '{"geometry":0.92,"visual_similarity":0.45}' > "$WORK/workdir/product-metrics.json"

cat > "$WORK/metric.yaml" <<'YAML'
kind: metric_score
file: product-metrics.json
path: $.geometry
minimum: 0.9
dimension: geometry
weight: 2
YAML
result="$(bash "$REPO_ROOT/scripts/eval/lib/score.sh" check "$WORK/metric.yaml" "$WORK/workdir" "$WORK/transcript.jsonl")"
[[ "$(printf '%s' "$result" | jq -r '.status')" == "PASS" ]] || { echo "FAIL: passing metric score did not pass: $result" >&2; exit 1; }
[[ "$(printf '%s' "$result" | jq -r '.score')" == "0.92" ]] || { echo "FAIL: metric score was not retained: $result" >&2; exit 1; }
[[ "$(printf '%s' "$result" | jq -r '.dimension')" == "geometry" ]] || { echo "FAIL: metric dimension was not retained: $result" >&2; exit 1; }
[[ "$(printf '%s' "$result" | jq -r '.weight')" == "2" ]] || { echo "FAIL: metric weight was not retained: $result" >&2; exit 1; }

cat > "$WORK/optional.yaml" <<'YAML'
kind: metric_score
file: product-metrics.json
path: $.visual_similarity
required: false
dimension: visual_similarity
YAML
result="$(bash "$REPO_ROOT/scripts/eval/lib/score.sh" check "$WORK/optional.yaml" "$WORK/workdir" "$WORK/transcript.jsonl")"
[[ "$(printf '%s' "$result" | jq -r '.score')" == "0.45" ]] || { echo "FAIL: report-only metric score missing: $result" >&2; exit 1; }


cat > "$WORK/optional-no-min.yaml" <<'YAML'
kind: metric_score
file: product-metrics.json
path: $.visual_similarity
required: false
dimension: optional_report
YAML
optional_result="$(run_check "$WORK/optional-no-min.yaml" "$WORK/workdir" "$WORK/transcript.jsonl")"
jq -e '.required == false and .status == "PASS" and .score == 0.45' <<< "$optional_result" >/dev/null \
  || { echo "FAIL: optional metric without a minimum was not preserved as report-only: $optional_result" >&2; exit 1; }
cat > "$WORK/product.yaml" <<'YAML'
schema_version: 2
id: product-metrics
 eval_type: product
checks:
  - kind: metric_score
    file: product-metrics.json
    path: $.geometry
    minimum: 0.8
    dimension: geometry
    weight: 2
  - kind: metric_score
    file: product-metrics.json
    path: $.visual_similarity
    minimum: 0.6
    required: false
    dimension: visual_similarity
YAML
# Remove the leading indentation from eval_type: this test also keeps the YAML contract strict.
sed 's/^ eval_type:/eval_type:/' "$WORK/product.yaml" > "$WORK/product-fixed.yaml"
run_all_checks "$WORK/product-fixed.yaml" "$WORK/workdir" "$WORK/transcript.jsonl" "$WORK/product-result.json"
jq -e '.evaluation_type=="product" and .compare_to_baseline==false and .passed==true and .fail_count==1 and .quality.dimensions.geometry.score==0.92 and .quality.dimensions.visual_similarity.score==0.45 and .quality.aggregate==null' "$WORK/product-result.json" >/dev/null \
  || { echo "FAIL: optional grader changed gate or dimensions were collapsed" >&2; cat "$WORK/product-result.json" >&2; exit 1; }

cat > "$WORK/human-pending.yaml" <<'YAML'
kind: human_review
file: review.json
dimension: visual_review
YAML
pending="$(bash "$REPO_ROOT/scripts/eval/lib/score.sh" check "$WORK/human-pending.yaml" "$WORK/workdir" "$WORK/transcript.jsonl")"
[[ "$(printf '%s' "$pending" | jq -r '.status')" == "PENDING" && "$(printf '%s' "$pending" | jq -r '.passed')" == "null" ]] \
  || { echo "FAIL: missing human review was not represented as pending: $pending" >&2; exit 1; }
cat > "$WORK/human-pending-case.yaml" <<'YAML'
schema_version: 2
id: human-pending
checks:
  - kind: human_review
    file: review.json
YAML
run_all_checks "$WORK/human-pending-case.yaml" "$WORK/workdir" "$WORK/transcript.jsonl" "$WORK/pending-result.json"
jq -e '.status=="NEEDS_REVIEW" and .needs_review==true and .passed==false' "$WORK/pending-result.json" >/dev/null \
  || { echo "FAIL: pending human review did not gate distinctly: $(cat "$WORK/pending-result.json")" >&2; exit 1; }

cat > "$WORK/workdir/review.json" <<'JSON'
{"schema_version":1,"status":"submitted","verdict":"PASS","reviewer":"reviewer-1","rubric_version":"img2threejs-product-v1","timestamp":"2026-09-29T00:00:00Z","rationale":"Geometry and editability evidence satisfy the rubric.","score":0.88}
JSON
reviewed="$(bash "$REPO_ROOT/scripts/eval/lib/score.sh" check "$WORK/human-pending.yaml" "$WORK/workdir" "$WORK/transcript.jsonl")"
[[ "$(printf '%s' "$reviewed" | jq -r '.status')" == "PASS" && "$(printf '%s' "$reviewed" | jq -r '.evidence.reviewer')" == "reviewer-1" ]] \
  || { echo "FAIL: submitted human review was not preserved: $reviewed" >&2; exit 1; }

cat > "$WORK/workdir/trajectory.jsonl" <<'JSONL'
{"seq":1,"type":"planning"}
{"seq":2,"type":"skill_selected","skill":"mesh-review"}
{"seq":3,"type":"tool_call","tool":"read","call_id":"c1"}
{"seq":4,"type":"tool_result","call_id":"c1","status":"failure"}
{"seq":5,"type":"retry","retry_of":"c1"}
{"seq":6,"type":"verification","id":"v1","status":"fail"}
{"seq":7,"type":"repair","repair_of":"v1","improved":true}
{"seq":8,"type":"verification","repair_of":"v1","status":"pass"}
{"seq":9,"type":"final_artifact","path":"model.glb"}
JSONL
cat > "$WORK/trajectory.yaml" <<'YAML'
kind: trajectory
file: trajectory.jsonl
required_events: [planning, skill_selected, verification, final_artifact]
required_skills: [mesh-review]
allowed_tools: [read]
max_tool_calls: 1
max_retries: 1
require_verification: true
require_successful_repair: true
dimension: execution
YAML
trajectory="$(bash "$REPO_ROOT/scripts/eval/lib/score.sh" check "$WORK/trajectory.yaml" "$WORK/workdir" "$WORK/transcript.jsonl")"
jq -e '.passed==true and .metrics.tool_calls==1 and .metrics.retries==1 and .metrics.failed_tool_calls==1 and .metrics.verified_repairs==1 and .dimension=="execution"' <<< "$trajectory" >/dev/null \
  || { echo "FAIL: normalized trajectory was not evaluated: $trajectory" >&2; exit 1; }
cat > "$WORK/missing-trajectory.yaml" <<'YAML'
kind: trajectory
file: absent.jsonl
max_tool_calls: 0
YAML
missing="$(bash "$REPO_ROOT/scripts/eval/lib/score.sh" check "$WORK/missing-trajectory.yaml" "$WORK/workdir" "$WORK/transcript.jsonl")"
[[ "$(printf '%s' "$missing" | jq -r '.status')" == "UNAVAILABLE" && "$(printf '%s' "$missing" | jq -r '.metrics.tool_calls')" == "null" ]] \
  || { echo "FAIL: absent trajectory was misreported as zero calls: $missing" >&2; exit 1; }

cat > "$WORK/outside.yaml" <<'YAML'
kind: metric_score
file: ../outside.json
path: $.score
minimum: 0.5
YAML
unsafe="$(bash "$REPO_ROOT/scripts/eval/lib/score.sh" check "$WORK/outside.yaml" "$WORK/workdir" "$WORK/transcript.jsonl")"
[[ "$(printf '%s' "$unsafe" | jq -r '.status')" == "ERROR" ]] || { echo "FAIL: artifact traversal was not rejected: $unsafe" >&2; exit 1; }

echo "PASS: artifact scores, optional dimensions, pending/reviewed human evidence, trajectory metrics, and unavailable-path handling"
