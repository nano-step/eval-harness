#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
WORK="$(mktemp -d -t eval-harness-grade-error.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/workdir"
cat > "$WORK/case.yaml" <<'YAML'
schema_version: 2
id: empty
prompt: noop
checks: []
YAML

source "$REPO_ROOT/scripts/eval/lib/portable.sh"
case_sha="$(portable_sha256_file "$WORK/case.yaml" | cut -d' ' -f1)"
work_sha="$(portable_tree_sha256 "$WORK/workdir")"
jq -n --arg cs "$case_sha" --arg ws "$work_sha" '{
  schema_version:1,run_id:"grade-error",case_id:"empty",mode:"deterministic",
  case_file:{path:"case.yaml",sha256:$cs},
  evidence:{workdir:{path:"workdir",status:"available",sha256:$ws},transcript:{path:"transcript.jsonl",status:"unavailable"},artifacts:[],environment_manifest:{path:"env-manifest.json",status:"unavailable"}},
  provenance:{}
}' > "$WORK/grading-manifest.json"

for strict in false true; do
  args=(--manifest="$WORK/grading-manifest.json")
  [[ "$strict" != true ]] || args+=(--strict)
  if bash "$REPO_ROOT/scripts/eval/grade.sh" "${args[@]}" >"$WORK/result-$strict.json" 2>"$WORK/stderr-$strict"; then
    rc=0
  else
    rc=$?
  fi
  [[ "$rc" -eq 13 ]] || { echo "FAIL: malformed grader config exited $rc (strict=$strict), expected 13" >&2; cat "$WORK/stderr-$strict" >&2; exit 1; }
  [[ "$(jq -r '.status' "$WORK/result-$strict.json")" == "ERROR" ]] || { echo "FAIL: malformed grader config was not ERROR" >&2; cat "$WORK/result-$strict.json" >&2; exit 1; }
done

echo "PASS: grade reports malformed case configuration as ERROR/13 with and without --strict"
