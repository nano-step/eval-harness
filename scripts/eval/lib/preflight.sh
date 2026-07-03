#!/usr/bin/env bash
# lib/preflight.sh — fail fast before spawning opencode sandboxes if env is broken.
#
# Three checks (all required to pass):
#   1. `opencode` binary is on PATH
#   2. `yq` is available, or the Python yq-shim fallback can run
#   3. At least one supported provider credential is set, OR an explicit
#      EVAL_SKIP_AUTH_CHECK=1 escape hatch (for local mock/offline development)
#
# Returns 0 if all checks pass, non-zero with a human-readable message on stderr otherwise.

set -euo pipefail

# Usage: preflight_check_langgraph
# Runner-aware companion to preflight_check. The langgraph-node runner
# does not invoke opencode, so it does not need a provider credential —
# only python3 on PATH. EVAL_SKIP_AUTH_CHECK is honored implicitly: it
# has no effect here (there is no LLM call to skip) but it is also
# not required.
preflight_check_langgraph() {
  if ! command -v python3 >/dev/null 2>&1; then
    echo "[eval-harness] preflight FAIL: runner=langgraph-node requires python3 on PATH" >&2
    return 1
  fi
  return 0
}

preflight_check() {
  local fail=0

  if ! command -v opencode >/dev/null 2>&1; then
    echo "[eval-harness] preflight FAIL: 'opencode' not on PATH" >&2
    fail=1
  fi

  if ! type -P yq >/dev/null 2>&1; then
    if ! command -v python3 >/dev/null 2>&1; then
      echo "[eval-harness] preflight FAIL: neither 'yq' binary nor 'python3' (for yq-shim fallback) on PATH" >&2
      fail=1
    elif ! python3 -c 'import yaml' 2>/dev/null; then
      echo "[eval-harness] preflight FAIL: 'yq' not on PATH and python3 lacks pyyaml. Run: pip install pyyaml" >&2
      fail=1
    fi
  fi

  if [[ "${EVAL_SKIP_AUTH_CHECK:-0}" == "1" ]]; then
    echo "[eval-harness] preflight: EVAL_SKIP_AUTH_CHECK=1 — skipping credential probe" >&2
    return "$fail"
  fi

  local has_cred=0
  for var in ANTHROPIC_API_KEY OPENROUTER_API_KEY OPENAI_API_KEY GOOGLE_GENERATIVE_AI_API_KEY; do
    local v="${!var:-}"
    if [[ -n "$v" && ${#v} -ge 20 && "$v" != *REDACTED* ]]; then
      has_cred=1
      break
    fi
  done

  if [[ "$has_cred" == "0" ]]; then
    for auth_path in \
      "${OPENCODE_AUTH_FILE:-}" \
      "$HOME/.local/share/opencode/auth.json" \
      "$HOME/.config/opencode/auth.json"
    do
      if [[ -n "$auth_path" && -s "$auth_path" ]]; then
        has_cred=1
        break
      fi
    done
  fi

  if [[ "$has_cred" == "0" ]]; then
    echo "[eval-harness] preflight FAIL: no usable provider credential found." >&2
    echo "  Env vars checked: ANTHROPIC_API_KEY OPENROUTER_API_KEY OPENAI_API_KEY GOOGLE_GENERATIVE_AI_API_KEY (each must be >=20 chars, non-REDACTED)" >&2
    echo "  Opencode auth checked: \$OPENCODE_AUTH_FILE, ~/.local/share/opencode/auth.json, ~/.config/opencode/auth.json (must exist + be non-empty)" >&2
    echo "  Either set a provider env var, log in via opencode, or set EVAL_SKIP_AUTH_CHECK=1." >&2
    fail=1
  fi

  return "$fail"
}

export -f preflight_check preflight_check_langgraph

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  preflight_check
fi
