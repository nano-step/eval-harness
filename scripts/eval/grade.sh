#!/usr/bin/env bash
# Grade externally produced artifacts without invoking a model or harness.
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
SCRIPT_DIR="$(_resolve_script_dir)"
source "$SCRIPT_DIR/lib/score.sh"
source "$SCRIPT_DIR/lib/portable.sh"

usage() {
  cat <<EOF
Usage: eval-harness grade --manifest=<grading-manifest.json> [--out=<result.json>] [--strict]

Grades a prepared artifact/workdir/transcript/trajectory from any runner. No model is spawned.
Manifest schema_version 1 requires run_id, case_id, case_file {path,sha256}, evidence.workdir {path,status},
optional evidence.transcript {path,status,sha256}, optional evidence.artifacts[] and provenance.
EOF
}

MANIFEST=""; OUT=""; STRICT=0
for arg in "$@"; do
  case "$arg" in
    --manifest=*) MANIFEST="${arg#*=}" ;;
    --out=*) OUT="${arg#*=}" ;;
    --strict) STRICT=1 ;;
    -h|--help) usage; exit 0 ;;
    grade) ;;
    *) echo "unknown arg: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

_emit_error() {
  local id="$1" expected="$2" actual="$3" hint="$4"
  jq -n --arg id "$id" --arg e "$expected" --arg a "$actual" --arg h "$hint" '{schema_version:1,passed:false,status:"ERROR",error:true,case_id:$id,expected:$e,actual:$a,diff_hint:$h}'
}

[[ -n "$MANIFEST" ]] || { echo "error: --manifest=<path> required" >&2; usage >&2; exit 2; }
[[ -f "$MANIFEST" ]] || { _emit_error "unknown" "grading manifest exists" "$MANIFEST" "manifest file not found"; exit 13; }
MANIFEST="$(cd "$(dirname "$MANIFEST")" && pwd)/$(basename "$MANIFEST")"
MANIFEST_ROOT="$(dirname "$MANIFEST")"
RAW="$(jq -c . "$MANIFEST" 2>/dev/null || echo null)"
[[ "$RAW" != "null" ]] || { _emit_error "unknown" "valid JSON manifest" "invalid JSON" "manifest could not be parsed"; exit 13; }
[[ "$(printf '%s' "$RAW" | jq -r '.schema_version // 0')" == "1" ]] || { _emit_error "unknown" "manifest schema_version 1" "unsupported schema" "upgrade or convert the grading manifest"; exit 13; }

_resolve_under_manifest() {
  local rel="$1"
  [[ -n "$rel" && "$rel" != /* && "$rel" != *..* ]] || return 1
  python3 -c '
import os,sys
root=os.path.realpath(sys.argv[1]); path=os.path.realpath(os.path.join(root,sys.argv[2]))
if path == root or path.startswith(root+os.sep): print(path)
else: raise SystemExit(1)
' "$MANIFEST_ROOT" "$rel"
}

case_id="$(printf '%s' "$RAW" | jq -r '.case_id // ""')"
run_id="$(printf '%s' "$RAW" | jq -r '.run_id // "external"')"
case_rel="$(printf '%s' "$RAW" | jq -r '.case_file.path // ""')"
case_sha="$(printf '%s' "$RAW" | jq -r '.case_file.sha256 // ""')"
work_rel="$(printf '%s' "$RAW" | jq -r '.evidence.workdir.path // ""')"
work_status="$(printf '%s' "$RAW" | jq -r '.evidence.workdir.status // "available"')"
transcript_rel="$(printf '%s' "$RAW" | jq -r '.evidence.transcript.path // ""')"
transcript_status="$(printf '%s' "$RAW" | jq -r '.evidence.transcript.status // "unavailable"')"
transcript_sha="$(printf '%s' "$RAW" | jq -r '.evidence.transcript.sha256 // ""')"
[[ -n "$case_id" && -n "$case_rel" && -n "$case_sha" && -n "$work_rel" ]] || { _emit_error "${case_id:-unknown}" "case_id, case_file.path+sha256, evidence.workdir.path" "required field missing" "manifest is incomplete"; exit 13; }
[[ "$work_status" == "available" ]] || { _emit_error "$case_id" "available workdir" "$work_status" "required artifact workdir is unavailable"; exit 13; }
case_path="$(_resolve_under_manifest "$case_rel" 2>/dev/null || true)"
workdir="$(_resolve_under_manifest "$work_rel" 2>/dev/null || true)"
[[ -n "$case_path" && -f "$case_path" ]] || { _emit_error "$case_id" "case file inside manifest root" "$case_rel" "case file missing or path unsafe"; exit 13; }
[[ -n "$workdir" && -d "$workdir" ]] || { _emit_error "$case_id" "workdir inside manifest root" "$work_rel" "workdir missing or path unsafe"; exit 13; }
work_sha="$(printf '%s' "$RAW" | jq -r '.evidence.workdir.sha256 // ""')"
[[ -n "$work_sha" ]] || { _emit_error "$case_id" "evidence.workdir.sha256" "missing" "workdir content is not bound to this manifest"; exit 13; }
actual_work_sha="$(portable_tree_sha256 "$workdir")"
[[ "$actual_work_sha" == "$work_sha" ]] || { _emit_error "$case_id" "workdir digest $work_sha" "$actual_work_sha" "workdir changed after manifest creation"; exit 13; }
actual_case_sha="$(portable_sha256_file "$case_path" | cut -d' ' -f1)"
[[ "$actual_case_sha" == "$case_sha" ]] || { _emit_error "$case_id" "case digest $case_sha" "$actual_case_sha" "case file changed after manifest creation"; exit 13; }
case_file_id="$(yq -r '.id // ""' "$case_path" 2>/dev/null || echo "")"
[[ "$case_file_id" == "$case_id" ]] || { _emit_error "$case_id" "case file id matches manifest" "$case_file_id" "manifest and case identity disagree"; exit 13; }
grading_mode="$(printf '%s' "$RAW" | jq -r '.mode // "deterministic"')"
case_mode="$(yq -r '.mode // "deterministic"' "$case_path" 2>/dev/null || echo deterministic)"
if [[ "$grading_mode" != "$case_mode" ]]; then
  _emit_error "$case_id" "manifest mode matches content-addressed case" "$grading_mode/$case_mode" "grading manifest evaluation mode disagrees with the case definition"
  exit 13
fi
if [[ "$case_mode" == "stochastic" ]]; then
  _emit_error "$case_id" "deterministic grading manifest" "stochastic" "stochastic aggregates require multiple sample workdirs and cannot be replayed as one artifact"
  exit 13
fi

case "$transcript_status" in
  available)
    transcript="$(_resolve_under_manifest "$transcript_rel" 2>/dev/null || true)"
    [[ -n "$transcript" && -f "$transcript" ]] || { _emit_error "$case_id" "available transcript inside manifest root" "$transcript_rel" "transcript missing or path unsafe"; exit 13; }
    [[ -n "$transcript_sha" ]] || { _emit_error "$case_id" "transcript.sha256" "missing" "available transcript is not content-addressed"; exit 13; }
    actual_transcript_sha="$(portable_sha256_file "$transcript" | cut -d' ' -f1)"
    [[ "$actual_transcript_sha" == "$transcript_sha" ]] || { _emit_error "$case_id" "transcript digest $transcript_sha" "$actual_transcript_sha" "transcript changed after manifest creation"; exit 13; }
    EVAL_TRANSCRIPT_UNAVAILABLE=0 ;;
  unavailable)
    transcript="$MANIFEST_ROOT/.unavailable-transcript"
    EVAL_TRANSCRIPT_UNAVAILABLE=1 ;;
  *) _emit_error "$case_id" "transcript status available or unavailable" "$transcript_status" "invalid transcript status"; exit 13 ;;
esac
export EVAL_TRANSCRIPT_UNAVAILABLE

env_rel="$(printf '%s' "$RAW" | jq -r '.evidence.environment_manifest.path // ""')"
env_status="$(printf '%s' "$RAW" | jq -r '.evidence.environment_manifest.status // "unavailable"')"
env_sha="$(printf '%s' "$RAW" | jq -r '.evidence.environment_manifest.sha256 // ""')"
case "$env_status" in
  available)
    env_path="$(_resolve_under_manifest "$env_rel" 2>/dev/null || true)"
    [[ -n "$env_path" && -f "$env_path" && -n "$env_sha" ]] || { _emit_error "$case_id" "available environment manifest path and digest" "$env_rel" "environment manifest missing or unbound"; exit 13; }
    actual_env_sha="$(portable_sha256_file "$env_path" | cut -d' ' -f1)"
    [[ "$actual_env_sha" == "$env_sha" ]] || { _emit_error "$case_id" "environment manifest digest $env_sha" "$actual_env_sha" "environment manifest changed after creation"; exit 13; } ;;
  unavailable) ;;
  *) _emit_error "$case_id" "environment manifest status available or unavailable" "$env_status" "invalid environment manifest status"; exit 13 ;;
esac

# Available artifact references are evidence, not inferred successes. Validate each path/digest.
while IFS=$'\t' read -r _role _path _status _sha; do
  [[ -z "$_role" ]] && continue
  if [[ "$_status" == "available" ]]; then
    _resolved="$(_resolve_under_manifest "$_path" 2>/dev/null || true)"
    [[ -n "$_resolved" && -f "$_resolved" ]] || { _emit_error "$case_id" "available artifact $_role exists inside manifest root" "$_path" "artifact missing or path unsafe"; exit 13; }
    [[ -n "$_sha" ]] || { _emit_error "$case_id" "artifact $_role sha256" "missing" "available evidence is not content-addressed"; exit 13; }
    _actual="$(portable_sha256_file "$_resolved" | cut -d' ' -f1)"
    [[ "$_actual" == "$_sha" ]] || { _emit_error "$case_id" "artifact $_role digest $_sha" "$_actual" "artifact changed after manifest creation"; exit 13; }
  elif [[ "$_status" != "unavailable" ]]; then
    _emit_error "$case_id" "artifact status available or unavailable" "$_status" "invalid evidence status"
    exit 13
  fi
done < <(jq -r '.evidence.artifacts[]? | [.role // "artifact", .path // "", .status // "unavailable", .sha256 // ""] | @tsv' "$MANIFEST")

GRADE_OUT="$(mktemp)"
run_all_checks "$case_path" "$workdir" "$transcript" "$GRADE_OUT"
manifest_sha="$(portable_sha256_file "$MANIFEST" | cut -d' ' -f1)"
result="$(jq --arg rid "$run_id" --arg cid "$case_id" --arg mpath "$(basename "$MANIFEST")" --arg msha "$manifest_sha" \
  --argjson provenance "$(printf '%s' "$RAW" | jq -c '.provenance // {}')" \
  --argjson artifacts "$(printf '%s' "$RAW" | jq -c '.evidence.artifacts // []')" \
  '. + {schema_version:1,run_id:$rid,case_id:$cid,grading_manifest:{path:$mpath,sha256:$msha},provenance:$provenance,evidence_artifacts:$artifacts}' "$GRADE_OUT")"
rm -f "$GRADE_OUT"
if [[ -n "$OUT" ]]; then mkdir -p "$(dirname "$OUT")"; printf '%s' "$result" > "$OUT"; fi
printf '%s' "$result"; echo
status="$(printf '%s' "$result" | jq -r '.status')"
[[ "$status" != "ERROR" ]] || exit 13
if [[ "$STRICT" == "1" ]]; then
  case "$status" in
    PASS) exit 0 ;;
    FAIL) exit 14 ;;
    NEEDS_REVIEW) exit 15 ;;
    INDETERMINATE) exit 16 ;;
  esac
fi
exit 0
