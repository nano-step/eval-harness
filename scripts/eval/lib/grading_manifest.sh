#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/portable.sh"

# Autonomous Test Discovery: bind EVERY atd-out file (primary and each stability sample), the candidate/spec/review
# files, and the stability metadata (stability.json + per-run checks.json + sample workdir digests) into the manifest.
# Emits NDJSON artifact records for one workdir root.
_gm_bind_root() {
  local wrel="$1" root="$2" cfgs="$3" out_rel f rel sha
  while IFS= read -r out_rel; do
    [[ -n "$out_rel" ]] || continue
    if [[ "$out_rel" == "." || "$out_rel" = /* || "/$out_rel/" == *"/../"* ]]; then
      jq -cn --arg p "$out_rel" '{role:"atd_evidence",path:$p,status:"unavailable",reason:"unsafe relative path"}'
      continue
    fi
    if [[ -d "$root/$out_rel" ]]; then
      while IFS= read -r -d '' f; do
        rel="${f#"$root"/}"
        if [[ -L "$f" ]]; then
          jq -cn --arg p "$wrel/$rel" '{role:"atd_evidence",path:$p,status:"unavailable",reason:"symlinks are not allowed in atd evidence"}'
        else
          sha="$(portable_sha256_file "$f" | cut -d' ' -f1)"
          jq -cn --arg p "$wrel/$rel" --arg s "$sha" '{role:"atd_evidence",path:$p,status:"available",sha256:$s}'
        fi
      done < <(find "$root/$out_rel" \( -type f -o -type l \) -print0 | portable_sort_nul)
    else
      jq -cn --arg p "$wrel/$out_rel" '{role:"atd_evidence",path:$p,status:"unavailable",reason:"atd evidence directory missing"}'
    fi
  done < <(jq -r '.[].out' <<<"$cfgs" | sort -u)
  while IFS= read -r rel; do
    [[ -n "$rel" ]] || continue
    if [[ "$rel" = /* || "/$rel/" == *"/../"* ]]; then
      jq -cn --arg p "$rel" '{role:"atd_input",path:$p,status:"unavailable",reason:"unsafe relative path"}'
    elif [[ -f "$root/$rel" && ! -L "$root/$rel" ]]; then
      sha="$(portable_sha256_file "$root/$rel" | cut -d' ' -f1)"
      jq -cn --arg p "$wrel/$rel" --arg s "$sha" '{role:"atd_input",path:$p,status:"available",sha256:$s}'
    else
      jq -cn --arg p "$wrel/$rel" '{role:"atd_input",path:$p,status:"unavailable",reason:"referenced evidence file missing"}'
    fi
  done < <(jq -r '.[].files[]' <<<"$cfgs" | sort -u)
}

# Prints {"artifacts":[...],"stability":null|{...}} for the case; empty for cases without discovery checks.
_gm_discovery_bind() {
  local checks_json="$1" workdir="$2" case_dir="$3" cfgs lines="" d idx csha stab_sha entries stab_json
  cfgs="$(jq -c '[.[] | select(.kind=="discovery_finding" or .kind=="discovery_test_health" or (.kind=="llm_judge" and .discovery_review==true))
      | {out:((.file // "atd-out/differential.json") | if test("/") then sub("/[^/]*$";"") else "." end),
         files:[(.candidate_file // "candidate.json"), (.spec_file // "SPEC.md"), (.expectation_review_file // "expectation-review.json")]}]' <<<"$checks_json" 2>/dev/null || echo '[]')"
  if [[ "$cfgs" == "[]" ]]; then echo '{"artifacts":[],"stability":null}'; return 0; fi
  lines="$(_gm_bind_root "$(basename "$workdir")" "$workdir" "$cfgs")"
  entries='[]'
  if [[ -f "$case_dir/checks.json" ]]; then
    csha="$(portable_sha256_file "$case_dir/checks.json" | cut -d' ' -f1)"
    lines="$lines"$'\n'"$(jq -cn --arg s "$csha" '{role:"atd_stability",path:"checks.json",status:"available",sha256:$s}')"
    entries="$(jq -cn --arg w "$(basename "$workdir")" --arg s "$csha" '[{index:1,workdir:$w,checks:{path:"checks.json",sha256:$s}}]')"
  fi
  for d in "$case_dir"/stability/sample-*; do
    [[ -d "$d/workdir" && -f "$d/checks.json" ]] || continue
    idx="${d##*/sample-}"
    [[ "$idx" =~ ^[0-9]+$ ]] || continue
    csha="$(portable_sha256_file "$d/checks.json" | cut -d' ' -f1)"
    lines="$lines"$'\n'"$(_gm_bind_root "stability/sample-$idx/workdir" "$d/workdir" "$cfgs")"
    lines="$lines"$'\n'"$(jq -cn --arg p "stability/sample-$idx/checks.json" --arg s "$csha" '{role:"atd_stability",path:$p,status:"available",sha256:$s}')"
    entries="$(jq -c --argjson i "$idx" --arg w "stability/sample-$idx/workdir" --arg p "stability/sample-$idx/checks.json" --arg s "$csha" --arg ws "$(portable_tree_sha256 "$d/workdir")" \
      '. + [{index:$i,workdir:$w,workdir_sha256:$ws,checks:{path:$p,sha256:$s}}]' <<<"$entries")"
  done
  stab_json=null
  if [[ -f "$case_dir/stability.json" ]]; then
    stab_sha="$(portable_sha256_file "$case_dir/stability.json" | cut -d' ' -f1)"
    lines="$lines"$'\n'"$(jq -cn --arg s "$stab_sha" '{role:"atd_stability",path:"stability.json",status:"available",sha256:$s}')"
    stab_json="$(jq -c --arg s "$stab_sha" --argjson e "$entries" '{status:"available",path:"stability.json",sha256:$s,performed:(.performed==true),samples:(.samples // 1),entries:$e}' "$case_dir/stability.json")"
  fi
  printf '%s\n' "$lines" | jq -cs --argjson st "$stab_json" '{artifacts:map(select(type=="object")),stability:$st}'
}

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
  local gm_extra gm_stab
  gm_extra="$(_gm_discovery_bind "$checks_json" "$workdir" "$(dirname "$out")")"
  artifacts_json="$(jq -c --argjson e "$gm_extra" '. + $e.artifacts' <<< "$artifacts_json")"
  gm_stab="$(jq -c '.stability' <<< "$gm_extra")"
  local env_json='{}'
  if [[ -f "$env_file" ]]; then env_json="$(cat "$env_file")"; fi
  jq -n \
    --arg run_id "$run_id" --arg case_id "$case_id" --arg mode "$mode" \
    --arg eval_type "$(yq -r '.eval_type // "regression"' "$case_file" 2>/dev/null || echo regression)" \
    --arg case_path "$(basename "$case_file")" --arg case_sha "$case_sha" \
    --arg workdir_path "$(basename "$workdir")" --arg workdir_sha "$workdir_sha" \
    --arg transcript_path "$(basename "$transcript")" --arg transcript_status "$transcript_status" --arg transcript_sha "$transcript_sha" \
    --arg env_status "$env_status" --arg env_sha "$env_sha" \
    --argjson artifacts "$artifacts_json" --argjson env "$env_json" --argjson stab "$gm_stab" \
'{schema_version:1,run_id:$run_id,case_id:$case_id,mode:$mode,eval_type:$eval_type,
      case_file:{path:$case_path,sha256:$case_sha},
      evidence:({
        workdir:{path:$workdir_path,status:"available",sha256:$workdir_sha},
        transcript:({path:$transcript_path,status:$transcript_status} + (if $transcript_status=="available" then {sha256:$transcript_sha} else {} end)),
        artifacts:$artifacts,
        environment_manifest:({path:"env-manifest.json",status:$env_status} + (if $env_status=="available" then {sha256:$env_sha} else {} end))
      } + (if $stab==null then {} else {stability:$stab} end)),
      provenance:{runner:{name:($env.runner // "opencode"),version:(($env.runner // "opencode") as $r | if $r=="opencode" then ($env.opencode_version // "unknown") elif $r=="langgraph-node" then ($env.langgraph_version // "unknown") else ($env.runner_version // "unknown") end)},model_id:($env.model_id // "unknown"),manifest_schema:($env.schema_version // null)}
    }' > "$out"
}

export -f write_case_grading_manifest
