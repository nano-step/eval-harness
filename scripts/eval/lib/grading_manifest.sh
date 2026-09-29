#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/portable.sh"

# Write a content-addressed, provider-neutral record for one case.
write_case_grading_manifest() {
  local case_file="$1" workdir="$2" transcript="$3" env_file="$4" run_id="$5" case_id="$6" out="$7"
  local case_sha workdir_sha transcript_status transcript_sha env_status env_sha artifacts_json checks_json rel target sha mode
  case_sha="$(portable_sha256_file "$case_file" | cut -d' ' -f1)"
  workdir_sha="$(portable_tree_sha256 "$workdir")"
  transcript_status="unavailable"; transcript_sha=""
  if [[ -f "$transcript" ]]; then transcript_status="available"; transcript_sha="$(portable_sha256_file "$transcript" | cut -d' ' -f1)"; fi
  env_status="unavailable"; env_sha=""
  if [[ -f "$env_file" ]]; then env_status="available"; env_sha="$(portable_sha256_file "$env_file" | cut -d' ' -f1)"; fi
  checks_json="$(yq -o=json '.checks // []' "$case_file" 2>/dev/null || echo '[]')"
mode="$(yq -r '.mode // "deterministic"' "$case_file" 2>/dev/null || echo deterministic)"
  artifacts_json="[]"
  while IFS= read -r rel; do
    [[ -z "$rel" ]] && continue
    case "/$rel/" in *"/../"*) artifacts_json="$(jq --arg p "$rel" '. + [{path:$p,status:"unavailable",reason:"unsafe relative path"}]' <<< "$artifacts_json")"; continue ;; esac
    if [[ "$rel" = /* ]]; then artifacts_json="$(jq --arg p "$rel" '. + [{path:$p,status:"unavailable",reason:"absolute paths are not allowed"}]' <<< "$artifacts_json")"; continue; fi
    target="$workdir/$rel"
    if [[ -f "$target" ]]; then
      sha="$(portable_sha256_file "$target" | cut -d' ' -f1)"
      artifacts_json="$(jq --arg p "workdir/$rel" --arg sha "$sha" '. + [{path:$p,status:"available",sha256:$sha}]' <<< "$artifacts_json")"
    else
      artifacts_json="$(jq --arg p "workdir/$rel" '. + [{path:$p,status:"unavailable",reason:"referenced evidence file missing"}]' <<< "$artifacts_json")"
    fi
  done < <(jq -r '[.[] | [(.file // empty),(.target_file // empty),(.review_file // empty),(if .kind=="human_review" then (.file // "human-review.json") else empty end),(if .kind=="trajectory" then (.file // "trajectory.jsonl") else empty end),(if .kind=="file_exists" then .path else empty end)] | .[]] | unique[]?' <<< "$checks_json")
  local env_json='{}'
  if [[ -f "$env_file" ]]; then env_json="$(cat "$env_file")"; fi
  jq -n \
    --arg run_id "$run_id" --arg case_id "$case_id" --arg mode "$mode" \
    --arg eval_type "$(yq -r '.eval_type // "regression"' "$case_file" 2>/dev/null || echo regression)" \
    --arg case_path "$(basename "$case_file")" --arg case_sha "$case_sha" \
    --arg workdir_path "$(basename "$workdir")" --arg workdir_sha "$workdir_sha" \
    --arg transcript_path "$(basename "$transcript")" --arg transcript_status "$transcript_status" --arg transcript_sha "$transcript_sha" \
    --arg env_status "$env_status" --arg env_sha "$env_sha" \
    --argjson artifacts "$artifacts_json" --argjson env "$env_json" \
'{schema_version:1,run_id:$run_id,case_id:$case_id,mode:$mode,eval_type:$eval_type,
      case_file:{path:$case_path,sha256:$case_sha},
      evidence:{
        workdir:{path:$workdir_path,status:"available",sha256:$workdir_sha},
        transcript:({path:$transcript_path,status:$transcript_status} + (if $transcript_status=="available" then {sha256:$transcript_sha} else {} end)),
        artifacts:$artifacts,
        environment_manifest:({path:"env-manifest.json",status:$env_status} + (if $env_status=="available" then {sha256:$env_sha} else {} end))
      },
      provenance:{runner:{name:($env.runner // "opencode"),version:(if $env.runner=="langgraph-node" then ($env.langgraph_version // "unknown") else ($env.opencode_version // "unknown") end)},model_id:($env.model_id // "unknown"),manifest_schema:($env.schema_version // null)}
    }' > "$out"
}

export -f write_case_grading_manifest
