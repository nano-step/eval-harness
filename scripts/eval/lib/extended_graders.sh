#!/usr/bin/env bash
set -euo pipefail

_score_normalize_jq_path() {
  local path="$1"
  case "$path" in
    '$') path='.' ;;
    '$.'*) path="$(printf '%s' "$path" | sed 's/^\$//')" ;;
    '$['*) path=".$(printf '%s' "$path" | sed 's/^\$//')" ;;
  esac
  printf '%s' "$path"
}

_score_resolve_workdir_file() {
  local root="$1" rel="$2"
  [[ -n "$rel" && "$rel" != /* && "$rel" != *..* ]] || return 1
  python3 -c 'import os,sys; r=os.path.realpath(sys.argv[1]); p=os.path.realpath(os.path.join(r,sys.argv[2])); print(p) if p != r and p.startswith(r+os.sep) else sys.exit(1)' "$root" "$rel"
}

_score_check_error() {
  local kind="$1" id="$2" expected="$3" actual="$4" hint="$5"
  jq -n --arg k "$kind" --arg id "$id" --arg e "$expected" --arg a "$actual" --arg h "$hint" '{kind:$k,passed:false,status:"ERROR",error:true,failed_check_id:($k+":"+$id),expected:$e,actual:$a,diff_hint:$h,score:null}'
}

_score_required_bool() {
  local cf="$1"
  yq -o=json '.' "$cf" 2>/dev/null | jq -r 'if .required == null then true else .required end' 2>/dev/null || echo true
}

score_metric_score() {
  local cf="$1" wd="$2" file path min req target actual type passed
  file="$(yq -r '.file // ""' "$cf" 2>/dev/null || echo "")"
  path="$(yq -r '.path // ""' "$cf" 2>/dev/null || echo "")"
  path="$(_score_normalize_jq_path "$path")"
  min="$(yq -r '.minimum // ""' "$cf" 2>/dev/null || echo "")"
  req="$(_score_required_bool "$cf")"
  if [[ -z "$file" || -z "$path" ]]; then _score_check_error metric_score config "file and path" "missing" "metric_score requires file and jq path"; return 0; fi
  if [[ "$req" == true && -z "$min" ]]; then _score_check_error metric_score "$file:$path" "minimum for required metric" "missing" "add minimum or set required: false"; return 0; fi
  if [[ -n "$min" ]] && ! [[ "$min" =~ ^(0([.][0-9]+)?|1([.]0+)?)$ ]]; then _score_check_error metric_score "$file:$path" "minimum in [0,1]" "$min" "minimum is not a valid score"; return 0; fi
  target="$(_score_resolve_workdir_file "$wd" "$file" 2>/dev/null || true)"
  if [[ -z "$target" ]]; then _score_check_error metric_score "$file:$path" "safe relative path" "$file" "metric artifact path escapes the workdir"; return 0; fi
  if [[ ! -f "$target" ]]; then
    jq -n --arg f "$file" --arg p "$path" '{kind:"metric_score",passed:null,status:"UNAVAILABLE",unavailable:true,failed_check_id:("metric_score:"+$f+":"+$p),expected:"numeric metric",actual:"artifact missing",diff_hint:("metric unavailable: "+$f),score:null,evidence:{path:$f,status:"missing"}}'
    return 0
  fi
  actual="$(jq -c "$path" "$target" 2>/dev/null || echo null)"
  type="$(printf '%s' "$actual" | jq -r type 2>/dev/null || echo invalid)"
  if [[ "$type" != number ]] || ! awk -v n="$actual" 'BEGIN{exit !(n>=0 && n<=1)}'; then _score_check_error metric_score "$file:$path" "number in [0,1]" "$actual" "metric path must resolve to a number between 0 and 1"; return 0; fi
  passed=true
  if [[ -n "$min" ]] && ! awk -v a="$actual" -v b="$min" 'BEGIN{exit !(a+0>=b+0)}'; then passed=false; fi
  jq -n --arg f "$file" --arg p "$path" --arg m "$min" --argjson s "$actual" --argjson ok "$passed" '{kind:"metric_score",passed:$ok,score:$s,failed_check_id:("metric_score:"+$f+":"+$p),expected:(if $m=="" then "reported score in [0,1]" else "score >= "+$m end),actual:$s,diff_hint:(if $ok then "" else "score below minimum "+$m end),evidence:{path:$f,jq_path:$p,status:"measured"}}'
}

score_human_review() {
  local cf="$1" wd="$2" file target record state verdict reviewer rubric timestamp rationale score ok
  file="$(yq -r '.review_file // ""' "$cf" 2>/dev/null || echo "")"
  [[ -n "$file" ]] || file="$(yq -r '.file // "human-review.json"' "$cf" 2>/dev/null || echo human-review.json)"
  target="$(_score_resolve_workdir_file "$wd" "$file" 2>/dev/null || true)"
  if [[ -z "$target" ]]; then _score_check_error human_review "$file" "safe relative path" "$file" "review path escapes the workdir"; return 0; fi
  if [[ ! -f "$target" ]]; then jq -n --arg f "$file" '{kind:"human_review",passed:null,status:"PENDING",review_required:true,failed_check_id:("human_review:"+$f),expected:"submitted human review",actual:"pending",diff_hint:"missing review is not a pass or candidate failure",score:null,evidence:{path:$f,status:"pending"}}'; return 0; fi
  record="$(jq -c . "$target" 2>/dev/null || echo null)"
  if [[ "$record" == null ]]; then _score_check_error human_review "$file" "valid review JSON" "invalid JSON" "review record could not be parsed"; return 0; fi
  state="$(printf '%s' "$record" | jq -r '.status // "submitted"')"
  if [[ "$state" == pending ]]; then jq -n --arg f "$file" --argjson r "$record" '{kind:"human_review",passed:null,status:"PENDING",review_required:true,failed_check_id:("human_review:"+$f),expected:"submitted human review",actual:"pending",diff_hint:"human review is still pending",score:null,evidence:{path:$f,status:"pending",record:$r}}'; return 0; fi
  verdict="$(printf '%s' "$record" | jq -r '.verdict // ""' | tr '[:lower:]' '[:upper:]')"
  reviewer="$(printf '%s' "$record" | jq -r '.reviewer // ""')"
  rubric="$(printf '%s' "$record" | jq -r '.rubric_version // ""')"
  timestamp="$(printf '%s' "$record" | jq -r '.timestamp // ""')"
  rationale="$(printf '%s' "$record" | jq -r '.rationale // ""')"
  if [[ "$verdict" != PASS && "$verdict" != FAIL ]] || [[ -z "$reviewer" || -z "$rubric" || -z "$timestamp" ]]; then _score_check_error human_review "$file" "schema_version 1, PASS/FAIL, reviewer, rubric_version, timestamp" "$record" "submitted record lacks required provenance"; return 0; fi
  score="$(printf '%s' "$record" | jq -r '.score // empty')"
  if [[ -z "$score" ]]; then [[ "$verdict" == PASS ]] && score=1 || score=0; elif ! [[ "$score" =~ ^(0([.][0-9]+)?|1([.]0+)?)$ ]]; then _score_check_error human_review "$file" "score in [0,1]" "$score" "review score is invalid"; return 0; fi
  ok=false; [[ "$verdict" == PASS ]] && ok=true
  jq -n --arg f "$file" --arg v "$verdict" --arg reviewer "$reviewer" --arg rubric "$rubric" --arg ts "$timestamp" --arg why "$rationale" --argjson s "$score" --argjson ok "$ok" '{kind:"human_review",passed:$ok,status:(if $ok then "PASS" else "FAIL" end),score:$s,failed_check_id:("human_review:"+$f),expected:"human verdict PASS",actual:$v,diff_hint:(if $ok then "" else "human reviewer rejected artifact" end),evidence:{path:$f,status:"submitted",reviewer:$reviewer,rubric_version:$rubric,timestamp:$ts,rationale:$why}}'
}

score_trajectory() {
  local cf="$1" wd="$2" file target events required_events required_skills allowed forbidden max_calls max_retries need_verify need_repair metrics missing_events missing_skills tool_violation forbidden_violation tool_calls retries verifications verified_repairs ok reasons
  file="$(yq -r '.file // "trajectory.jsonl"' "$cf" 2>/dev/null || echo trajectory.jsonl)"
  target="$(_score_resolve_workdir_file "$wd" "$file" 2>/dev/null || true)"
  if [[ -z "$target" ]]; then _score_check_error trajectory "$file" "safe relative path" "$file" "trajectory path escapes the workdir"; return 0; fi
  if [[ ! -f "$target" ]]; then jq -n --arg f "$file" '{kind:"trajectory",passed:null,status:"UNAVAILABLE",unavailable:true,failed_check_id:("trajectory:"+$f),expected:"normalized trajectory JSONL",actual:"trajectory missing",diff_hint:"trajectory unavailable; calls and retries are not zero",score:null,metrics:{tool_calls:null,retries:null,failed_tool_calls:null,verification_events:null,verified_repairs:null},evidence:{path:$f,status:"missing"}}'; return 0; fi
  events="$(jq -s . "$target" 2>/dev/null || echo null)"
  if [[ "$(printf '%s' "$events" | jq -r type 2>/dev/null || echo invalid)" != array ]] || ! printf '%s' "$events" | jq -e 'all(.[]; type=="object" and (.seq|type)=="number" and (.type|type)=="string") and ([.[].seq] == ([.[].seq]|sort|unique))' >/dev/null 2>&1; then _score_check_error trajectory "$file" "JSONL objects with increasing unique seq and type" "invalid trajectory" "trajectory schema validation failed"; return 0; fi
  required_events="$(yq -o=json '.required_events // []' "$cf" 2>/dev/null || echo '[]')"
  required_skills="$(yq -o=json '.required_skills // []' "$cf" 2>/dev/null || echo '[]')"
  allowed="$(yq -o=json '.allowed_tools // []' "$cf" 2>/dev/null || echo '[]')"
  forbidden="$(yq -o=json '.forbidden_tools // []' "$cf" 2>/dev/null || echo '[]')"
  max_calls="$(yq -r '.max_tool_calls // ""' "$cf" 2>/dev/null || echo "")"
  max_retries="$(yq -r '.max_retries // ""' "$cf" 2>/dev/null || echo "")"
  need_verify="$(yq -r '.require_verification // false' "$cf" 2>/dev/null || echo false)"
  need_repair="$(yq -r '.require_successful_repair // false' "$cf" 2>/dev/null || echo false)"
  if [[ "$(printf '%s' "$required_events"|jq -r type)" != array || "$(printf '%s' "$required_skills"|jq -r type)" != array || "$(printf '%s' "$allowed"|jq -r type)" != array || "$(printf '%s' "$forbidden"|jq -r type)" != array ]] || { [[ -n "$max_calls" ]] && ! [[ "$max_calls" =~ ^[0-9]+$ ]]; } || { [[ -n "$max_retries" ]] && ! [[ "$max_retries" =~ ^[0-9]+$ ]]; } || { [[ "$need_verify" != true && "$need_verify" != false ]]; } || { [[ "$need_repair" != true && "$need_repair" != false ]]; }; then _score_check_error trajectory "$file" "valid arrays, booleans, and integer limits" "invalid rules" "trajectory rule configuration is malformed"; return 0; fi
  metrics="$(jq -n --argjson e "$events" '{tool_calls:([$e[]|select(.type=="tool_call")]|length),retries:([$e[]|select(.type=="retry")]|length),failed_tool_calls:([$e[]|select(.type=="tool_result" and (.status=="error" or .status=="failure"))]|length),verification_events:([$e[]|select(.type=="verification")]|length),verification_failures:([$e[]|select(.type=="verification" and (.status=="fail" or .status=="failed"))]|length),verified_repairs:([$e[] as $v|select($v.type=="verification" and ($v.status=="fail" or $v.status=="failed") and ($v.id|type)=="string")|select(any($e[];.type=="repair" and .repair_of==$v.id and .improved==true))|select(any($e[];.type=="verification" and .repair_of==$v.id and (.status=="pass" or .status=="passed"))) ]|length)}')"
  missing_events="$(jq -n --argjson e "$events" --argjson r "$required_events" '[ $r[] as $v|select(([ $e[]|.type ]|index($v))==null)|$v ]')"
  missing_skills="$(jq -n --argjson e "$events" --argjson r "$required_skills" '[ $r[] as $v|select(([ $e[]|select(.type=="skill_selected")|.skill ]|index($v))==null)|$v ]')"
  tool_violation="$(jq -n --argjson e "$events" --argjson a "$allowed" '[ $e[] as $v|select($v.type=="tool_call")|select(($a|length)>0 and ($a|index($v.tool))==null)|$v.tool ]')"
  forbidden_violation="$(jq -n --argjson e "$events" --argjson f "$forbidden" '[ $e[] as $v|select($v.type=="tool_call")|select(($f|index($v.tool))!=null)|$v.tool ]')"
  tool_calls="$(printf '%s' "$metrics"|jq -r '.tool_calls')"; retries="$(printf '%s' "$metrics"|jq -r '.retries')"; verifications="$(printf '%s' "$metrics"|jq -r '.verification_events')"; verified_repairs="$(printf '%s' "$metrics"|jq -r '.verified_repairs')"
  ok=true; reasons='[]'
  if [[ "$(printf '%s' "$missing_events"|jq length)" -gt 0 ]]; then ok=false; reasons="$(jq -n --argjson a "$reasons" --argjson b "$missing_events" '$a+["missing events: "+($b|join(", "))]')"; fi
  if [[ "$(printf '%s' "$missing_skills"|jq length)" -gt 0 ]]; then ok=false; reasons="$(jq -n --argjson a "$reasons" --argjson b "$missing_skills" '$a+["missing skills: "+($b|join(", "))]')"; fi
  if [[ "$(printf '%s' "$tool_violation"|jq length)" -gt 0 ]]; then ok=false; reasons="$(jq -n --argjson a "$reasons" --argjson b "$tool_violation" '$a+["tools outside allowlist: "+($b|unique|join(", "))]')"; fi
  if [[ "$(printf '%s' "$forbidden_violation"|jq length)" -gt 0 ]]; then ok=false; reasons="$(jq -n --argjson a "$reasons" --argjson b "$forbidden_violation" '$a+["forbidden tools: "+($b|unique|join(", "))]')"; fi
  if [[ -n "$max_calls" && "$tool_calls" -gt "$max_calls" ]]; then ok=false; reasons="$(jq -n --argjson a "$reasons" --arg n "$tool_calls" --arg m "$max_calls" '$a+["tool_calls="+$n+" exceeds max_tool_calls="+$m]')"; fi
  if [[ -n "$max_retries" && "$retries" -gt "$max_retries" ]]; then ok=false; reasons="$(jq -n --argjson a "$reasons" --arg n "$retries" --arg m "$max_retries" '$a+["retries="+$n+" exceeds max_retries="+$m]')"; fi
  if [[ "$need_verify" == true && "$verifications" -eq 0 ]]; then ok=false; reasons="$(jq -n --argjson a "$reasons" '$a+["verification event missing"]')"; fi
  if [[ "$need_repair" == true && "$(printf '%s' "$metrics"|jq -r '.verification_failures')" -gt "$verified_repairs" ]]; then ok=false; reasons="$(jq -n --argjson a "$reasons" '$a+["failed verification lacks an explicitly linked improved repair and passing verification"]')"; fi
  jq -n --arg f "$file" --argjson ok "$ok" --argjson m "$metrics" --argjson r "$reasons" '{kind:"trajectory",passed:$ok,score:(if $ok then 1 else 0 end),failed_check_id:("trajectory:"+$f),expected:"declared trajectory rules satisfied",actual:$m,diff_hint:($r|join("; ")),metrics:$m,evidence:{path:$f,status:"measured"}}'
}

decorate_check_result() {
  local check_file="$1" result="$2" dimension weight required
  dimension="$(yq -r '.dimension // ""' "$check_file" 2>/dev/null || echo "")"
  [[ -n "$dimension" ]] || dimension="$(yq -r '.kind // "unknown"' "$check_file" 2>/dev/null || echo unknown)"
  weight="$(yq -r '.weight // 1' "$check_file" 2>/dev/null || echo 1)"
  required="$(_score_required_bool "$check_file")"
  if [[ -z "$dimension" || ( "$required" != true && "$required" != false ) || ! "$weight" =~ ^([0-9]+([.][0-9]+)?|[.][0-9]+)$ ]] || ! awk -v w="$weight" 'BEGIN{exit !(w>0)}'; then
    _score_check_error "$(printf '%s' "$result"|jq -r '.kind // "unknown"')" config "dimension, boolean required, positive weight" "$dimension/$required/$weight" "check grading metadata is malformed"
    return 0
  fi
  jq --arg d "$dimension" --argjson w "$weight" --argjson req "$required" '. + {dimension:$d,weight:$w,required:$req} | .score=(if has("score") then .score elif .passed==true then 1 elif .passed==false then 0 else null end) | .status=(.status // (if .review_required then "PENDING" elif .unavailable then "UNAVAILABLE" elif .error then "ERROR" elif .passed==true then "PASS" elif .passed==false then "FAIL" else "ABSTAIN" end))' <<< "$result"
}
