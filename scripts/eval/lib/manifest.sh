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

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/portable.sh"

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

  # Skill bundle sha: hash the entire .opencode/skills/ tree (transitive, per Settled #14).
  # This catches cross-skill regressions where editing skill B silently affects skill A.
  # NOTE: we use a while-read loop instead of `xargs -0 sha256sum` because
  # run.sh's heavy `export -f` of all lib functions bloats the environment
  # beyond Windows MSYS's exec limit, causing xargs to fail with
  # "environment is too large for exec". The while loop reads null-separated
  # paths in the parent shell and invokes sha256sum via the same shell,
  # sidestepping the exec limit.
  local skill_bundle_sha
  if [[ -d "$skills_root" ]]; then
    skill_bundle_sha="$(cd "$skills_root" && find . -type f \( -name "*.md" -o -name "*.sh" -o -name "*.yaml" -o -name "*.json" \) -print0 \
      | sort -z \
      | while IFS= read -r -d '' file; do portable_sha256_file "$file"; done \
      | portable_sha256_stdin \
      | cut -d' ' -f1)"
  else
    skill_bundle_sha="missing"
  fi

  # Per-skill sha: just this skill's files
  local skill_sha="missing"
  if [[ -d "$skill_dir" ]]; then
    skill_sha="$(cd "$skill_dir" && find . -type f -print0 \
      | sort -z \
      | while IFS= read -r -d '' file; do portable_sha256_file "$file"; done \
      | portable_sha256_stdin \
      | cut -d' ' -f1)"
  fi

  # Fixture sha: case-specific fixture directory if EVAL_FIXTURE_DIR set
  local fixture_sha="none"
  if [[ -n "${EVAL_FIXTURE_DIR:-}" ]] && [[ -d "$EVAL_FIXTURE_DIR" ]]; then
    fixture_sha="$(cd "$EVAL_FIXTURE_DIR" && find . -type f -print0 \
      | sort -z \
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
    --arg fixture_sha "$fixture_sha" \
    --arg timestamp "$timestamp" \
    --arg skill "$skill" \
    --arg runner "$runner" \
    --arg runner_config_sha "$runner_config_sha" \
    --arg graph_fingerprint "$graph_fingerprint" \
    --arg langgraph_version "$langgraph_version" \
    --arg python_version "$python_version" \
    '{
      schema_version: 2,
      opencode_version: $opencode_version,
      model_id: $model_id,
      node_version: $node_version,
      platform: $platform,
      skill_under_test: $skill,
      skill_bundle_sha: $skill_bundle_sha,
      skill_sha: $skill_sha,
      fixture_sha: $fixture_sha,
      runner: $runner,
      runner_config_sha: $runner_config_sha,
      graph_fingerprint: $graph_fingerprint,
      langgraph_version: $langgraph_version,
      python_version: $python_version,
      timestamp: $timestamp
    }' > "$out"
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
    | [(($bm | keys) + ($cm | keys)) | unique[]] as $all_keys
    | [$all_keys[] | select(($bm[.]) != ($cm[.])) | select(. != "timestamp")] as $changed
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
