#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/skills/eval-harness"
printf '# test skill\n' > "$TMP/skills/eval-harness/SKILL.md"
cat > "$TMP/case.yaml" <<'YAML'
schema_version: 2
id: prompt-case
prompt: "describe the mesh"
eval_type: product
checks:
  - kind: metric_score
    file: metrics.json
    path: $.quality.mesh
    minimum: 0.8
    dimension: geometry
YAML
printf '{"tools":["inspect"]}\n' > "$TMP/tools.json"
export OPENCODE_SKILLS_ROOT="$TMP/skills"
export EVAL_CASE_FILE="$TMP/case.yaml"
export EVAL_TOOL_MANIFEST_FILE="$TMP/tools.json"
source "$SCRIPT_DIR/lib/yq-shim.sh"
source "$SCRIPT_DIR/lib/manifest.sh"
source "$SCRIPT_DIR/lib/attribute.sh"
capture_manifest eval-harness "$TMP/current.json"
[[ "$(jq -r '.schema_version' "$TMP/current.json")" == "4" ]]
for key in prompt_sha rubric_sha tool_manifest_sha; do
  value="$(jq -r --arg k "$key" '.[$k] // empty' "$TMP/current.json")"
  [[ "${#value}" -eq 64 ]]
done

jq 'del(.prompt_sha,.rubric_sha,.tool_manifest_sha) | .schema_version=3' "$TMP/current.json" > "$TMP/legacy.json"
legacy_delta="$(diff_manifests "$TMP/legacy.json" "$TMP/current.json")"
[[ "$(printf '%s' "$legacy_delta" | jq '.keys_changed|length')" == "0" ]]
echo 'PASS v3 environment baselines ignore newly introduced hashes'

printf '{"tools":["inspect","geometry"]}\n' > "$TMP/tools.json"
capture_manifest eval-harness "$TMP/current-changed.json"
tool_delta="$(diff_manifests "$TMP/current.json" "$TMP/current-changed.json")"
[[ "$(printf '%s' "$tool_delta" | jq -r '.keys_changed|join(",")')" == "tool_manifest_sha" ]]
tool_attribution="$(attribute "$tool_delta")"
[[ "$(printf '%s' "$tool_attribution" | jq -r '.top')" == "TOOL_MANIFEST_CHANGED" ]]
echo 'PASS tool manifest digest change is attributed from direct evidence'

jq '.prompt_sha="different"' "$TMP/current.json" > "$TMP/prompt-changed.json"
prompt_delta="$(diff_manifests "$TMP/current.json" "$TMP/prompt-changed.json")"
prompt_attribution="$(attribute "$prompt_delta")"
[[ "$(printf '%s' "$prompt_attribution" | jq -r '.top')" == "PROMPT_CHANGED" ]]
echo 'PASS prompt hash change has a distinct attribution class'
