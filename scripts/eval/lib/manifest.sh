#!/usr/bin/env bash
# lib/manifest.sh — capture environment manifest for reproducibility
# Settled Decision #8: env-manifest per run with opencode version, model, skill bundle sha,
# MCP availability, git SHA, timestamp, node version, platform.
#
# U1 extension: adds runner-aware fields. For the opencode runner, the
# langgraph_* / graph_fingerprint fields are "none" (opencode is the
# implicit default and does not use a graph). For langgraph-node and
# future runners, the caller sets EVAL_RUNNER and EVAL_GRAPH_FINGERPRINT
# / EVAL_RUNNER_CONFIG_SHA before invoking capture_manifest.

set -euo pipefail

if ! declare -F resolve_skills_root >/dev/null; then
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/skills_root.sh"
fi
if ! command -v yq >/dev/null 2>&1; then
  source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/yq-shim.sh"
fi

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/portable.sh"

_MANIFEST_HASH_ROOT=""
_MANIFEST_BUNDLE_SHA=""
_MANIFEST_PERSKILL_JSON="{}"

_manifest_hash_tree() {
  local root="$1" kind="$2"
  (
    cd "$root" || exit 1
    if [[ "$kind" == "bundle" ]]; then
      find . -type f \( -name '*.md' -o -name '*.sh' -o -name '*.yaml' -o -name '*.json' \) -not -path '*/evals/baselines/*' -print0
    else
      find . -type f -not -path '*/evals/baselines/*' -print0
    fi | portable_sort_nul | while IFS= read -r -d '' file; do
      file_sha="$(portable_sha256_file "$file" | cut -d' ' -f1)"
      printf '%s  %s\n' "$file_sha" "$file"
    done
  ) | portable_sha256_stdin | cut -d' ' -f1
}

_manifest_compute_hashes() {
  local root="$1"
  [[ "$_MANIFEST_HASH_ROOT" == "$root" && -n "$_MANIFEST_BUNDLE_SHA" ]] && return 0
  if [[ -d "$root" ]]; then
    _MANIFEST_BUNDLE_SHA="$(_manifest_hash_tree "$root" bundle)"
    local entries=() dir name sha
    for dir in "$root"/*/; do
      [[ -d "$dir" ]] || continue
      name="$(basename "$dir")"
      sha="$(_manifest_hash_tree "$dir" all)"
      entries+=("$(jq -nc --arg n "$name" --arg s "$sha" '{($n): $s}')")
    done
    if [[ ${#entries[@]} -gt 0 ]]; then
      _MANIFEST_PERSKILL_JSON="$(printf '%s\n' "${entries[@]}" | jq -s 'add // {}')"
    else
      _MANIFEST_PERSKILL_JSON="{}"
    fi
  else
    _MANIFEST_BUNDLE_SHA="missing"
    _MANIFEST_PERSKILL_JSON="{}"
  fi
  _MANIFEST_HASH_ROOT="$root"
}

# Usage: capture_manifest <skill_under_test> <output_path>
# Writes a JSON manifest to <output_path>
capture_manifest() {
  local skill="$1"
  local out="$2"
  local skills_root
  skills_root="$(resolve_skills_root)"
  local skill_dir="$skills_root/$skill"

  local opencode_version
  opencode_version="$(opencode --version 2>/dev/null | head -1 || echo "unknown")"

  local node_version
  node_version="$(node --version 2>/dev/null || echo "unknown")"

  local platform
  platform="$(uname -s)-$(uname -m)"

  local model_id="${EVAL_CASE_MODEL:-${EVAL_MODEL:-${OPENCODE_MODEL:-unknown}}}"
  local prompt_sha="" rubric_sha="" tool_manifest_extra='{}' case_file_for_manifest tool_manifest_file
  case_file_for_manifest="$(printenv EVAL_CASE_FILE 2>/dev/null || echo "")"
  tool_manifest_file="$(printenv EVAL_TOOL_MANIFEST_FILE 2>/dev/null || echo "")"
  if [[ -n "$case_file_for_manifest" && -f "$case_file_for_manifest" ]]; then
    prompt_sha="$(yq -o=json '.prompt // ""' "$case_file_for_manifest" 2>/dev/null | portable_sha256_stdin | cut -d' ' -f1)"
    rubric_sha="$(yq -o=json '.checks // []' "$case_file_for_manifest" 2>/dev/null | jq -S . | portable_sha256_stdin | cut -d' ' -f1)"
  fi
  if [[ -n "$tool_manifest_file" && -f "$tool_manifest_file" ]]; then
    _tool_sha="$(portable_sha256_file "$tool_manifest_file" | cut -d' ' -f1)"
    tool_manifest_extra="$(jq -nc --arg sha "$_tool_sha" '{tool_manifest_sha:$sha}')"
  fi
  # Skill bundle + per-skill SHA: computed once per process (memoized; see _manifest_compute_hashes).
  # Excludes evals/baselines/ — recorded baselines are OUTPUTS, not skill behavior (#EV-1).
  _manifest_compute_hashes "$skills_root"
  local skill_bundle_sha="$_MANIFEST_BUNDLE_SHA"
  local per_skill_sha_json="$_MANIFEST_PERSKILL_JSON"
  # The SUT's skill_sha is its entry in the per-skill map (no separate hashing pass).
  local skill_sha
  skill_sha="$(printf '%s' "$per_skill_sha_json" | jq -r --arg s "$skill" '.[$s] // "missing"')"

  # Fixture sha: case-specific fixture directory if EVAL_FIXTURE_DIR set
  local fixture_sha="none"
  if [[ -n "${EVAL_FIXTURE_DIR:-}" ]] && [[ -d "$EVAL_FIXTURE_DIR" ]]; then
    fixture_sha="$(cd "$EVAL_FIXTURE_DIR" && find . -type f -print0 \
      | portable_sort_nul \
      | while IFS= read -r -d '' file; do portable_sha256_file "$file"; done \
      | portable_sha256_stdin \
      | cut -d' ' -f1)"
  fi

  local timestamp
  timestamp="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  # Runner-aware fields. Defaults: runner="opencode" (implicit), all graph
  # fields "none". Callers may override via env: EVAL_RUNNER,
  # EVAL_GRAPH_FINGERPRINT, EVAL_RUNNER_CONFIG_SHA, EVAL_LANGGRAPH_VERSION,
  # EVAL_PYTHON_VERSION.
  local runner="${EVAL_RUNNER:-opencode}"
  local graph_fingerprint="${EVAL_GRAPH_FINGERPRINT:-none}"
  local runner_config_sha="${EVAL_RUNNER_CONFIG_SHA:-none}"
  local langgraph_version="${EVAL_LANGGRAPH_VERSION:-none}"
  local python_version="${EVAL_PYTHON_VERSION:-none}"

  # If the caller didn't pre-set the python/langgraph versions, probe
  # once and silently default to "none" on failure (don't break manifest
  # capture if python3 is missing or langgraph isn't installed).
  if [[ "$python_version" == "none" ]] && command -v python3 >/dev/null 2>&1; then
    python_version="$(python3 --version 2>/dev/null | head -1 | sed 's/^Python //')"
  fi
  if [[ "$langgraph_version" == "none" ]] && command -v python3 >/dev/null 2>&1; then
    langgraph_version="$(python3 -c "import langgraph; print(langgraph.__version__)" 2>/dev/null || echo none)"
  fi

jq -n \
  --arg opencode_version "$opencode_version" \
  --arg model_id "$model_id" \
  --arg node_version "$node_version" \
  --arg platform "$platform" \
  --arg skill_bundle_sha "$skill_bundle_sha" \
  --arg skill_sha "$skill_sha" \
  --argjson per_skill_sha "$per_skill_sha_json" \
  --arg fixture_sha "$fixture_sha" \
  --arg timestamp "$timestamp" \
  --arg skill "$skill" \
  --arg prompt_sha "$prompt_sha" \
  --arg rubric_sha "$rubric_sha" \
  --arg runner "$runner" \
  --arg runner_config_sha "$runner_config_sha" \
  --arg graph_fingerprint "$graph_fingerprint" \
  --arg langgraph_version "$langgraph_version" \
  --arg python_version "$python_version" \
  --argjson tool_extra "$tool_manifest_extra" \
  '{
    schema_version: 4,
    opencode_version: $opencode_version,
    model_id: $model_id,
    node_version: $node_version,
    platform: $platform,
    skill_under_test: $skill,
    skill_bundle_sha: $skill_bundle_sha,
    skill_sha: $skill_sha,
    per_skill_sha: $per_skill_sha,
    fixture_sha: $fixture_sha,
    prompt_sha: $prompt_sha,
    rubric_sha: $rubric_sha,
    runner: $runner,
    runner_config_sha: $runner_config_sha,
    graph_fingerprint: $graph_fingerprint,
    langgraph_version: $langgraph_version,
    python_version: $python_version,
    timestamp: $timestamp
  } + $tool_extra' > "$out"
}

# Usage: diff_manifests <baseline_manifest_path> <current_manifest_path>
# Emits JSON: {keys_changed: [...], details: {key: {baseline, current}, ...}}
diff_manifests() {
  local baseline="$1"
  local current="$2"

  if [[ ! -f "$baseline" ]]; then
    echo '{"keys_changed": ["__no_baseline__"], "details": {}}'
    return 0
  fi

  jq -n \
    --slurpfile b "$baseline" \
    --slurpfile c "$current" \
    '
    ($b[0] // {}) as $bm
    | ($c[0] // {}) as $cm
    # (#EV-P0a/C1) A portable shipped baseline makes no environment claim: ignore ONLY
    # model_id + opencode_version so it never false-flags MODEL_CHANGED across machines.
    # We do NOT short-circuit (that would mask skill_sha/fixture_sha/per_skill_sha deltas
    # as UNKNOWN_DRIFT) — every other key is still compared normally.
    | ($bm.portable == true) as $portable
    | (["schema_version", "timestamp", "portable"] + (if $portable then ["model_id", "opencode_version"] else [] end)) as $ignore
    | [(($bm | keys) + ($cm | keys)) | unique[]] as $all_keys
    | (["prompt_sha", "rubric_sha", "tool_manifest_sha", "per_skill_sha", "runner", "runner_config_sha", "graph_fingerprint", "langgraph_version", "python_version"]) as $new_hash_keys
    | [$all_keys[] as $k
        | select(($bm | has($k)) or (($new_hash_keys | index($k)) == null))
        | select($bm[$k] != $cm[$k])
        | select(($ignore | index($k)) == null)
        | $k
      ] as $changed
    | {
        keys_changed: $changed,
        details: ($changed | map({(.): {baseline: $bm[.], current: $cm[.]}}) | add // {})
      }
    '
}

# Export functions if sourced
export -f capture_manifest
export -f diff_manifests

# Allow direct invocation: lib/manifest.sh capture <skill> <out>
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-}" in
    capture) shift; capture_manifest "$@" ;;
    diff)    shift; diff_manifests "$@" ;;
    *) echo "usage: manifest.sh {capture <skill> <out> | diff <baseline> <current>}" >&2; exit 2 ;;
  esac
fi
