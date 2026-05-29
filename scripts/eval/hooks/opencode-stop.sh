#!/usr/bin/env bash
# Hook for opencode's `tool.execute.after` / `session.idle` events.
#
# Requires opencode plugin API >= 1.16.x (Stop hook lifecycle was not stable in
# 1.15.10 — version gate below). When loaded by opencode, this script receives
# the changed-files set in env var OPENCODE_CHANGED_FILES (NUL-separated, per
# plugin protocol draft 2026-Q1).
#
# Status: SCAFFOLD — wiring into opencode is gated on upstream plugin API
# verification. Until then this script can be invoked manually as:
#   OPENCODE_CHANGED_FILES="path/skill/SKILL.md" bash opencode-stop.sh
# to exercise the same code path that opencode will eventually call.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_BIN="$SCRIPT_DIR/../run.sh"

REQUIRED_OPENCODE_MAJOR=1
REQUIRED_OPENCODE_MINOR=16

require_opencode_version() {
  if ! command -v opencode >/dev/null 2>&1; then
    echo "[opencode-stop] opencode not on PATH — skipping" >&2
    return 1
  fi
  local v
  v="$(opencode --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1 || echo "0.0")"
  local maj="${v%%.*}"
  local min="${v##*.}"
  if [[ "$maj" -lt "$REQUIRED_OPENCODE_MAJOR" ]] || { [[ "$maj" == "$REQUIRED_OPENCODE_MAJOR" ]] && [[ "$min" -lt "$REQUIRED_OPENCODE_MINOR" ]]; }; then
    echo "[opencode-stop] requires opencode >= ${REQUIRED_OPENCODE_MAJOR}.${REQUIRED_OPENCODE_MINOR} (have $v) — skipping. Stop-hook plugin API was not stable before 1.16." >&2
    return 1
  fi
  return 0
}

discover_changed_skills() {
  local files="${OPENCODE_CHANGED_FILES:-}"
  if [[ -z "$files" ]]; then return 0; fi
  printf '%s' "$files" | tr '\0\n' '\n\n' | awk -F'/' '
    /\.opencode\/skills\// {
      for (i=1; i<=NF; i++) if ($i == "skills" && (i+1)<=NF) { print $(i+1); next }
    }
  ' | sort -u
}

main() {
  if ! require_opencode_version; then exit 0; fi

  local changed_skills=()
  mapfile -t changed_skills < <(discover_changed_skills)
  if [[ ${#changed_skills[@]} -eq 0 ]]; then
    echo "[opencode-stop] no skill files changed; nothing to evaluate" >&2
    exit 0
  fi

  local skill
  local exit_aggregate=0
  for skill in "${changed_skills[@]}"; do
    [[ -z "$skill" ]] && continue
    echo "[opencode-stop] running evals for changed skill: $skill" >&2
    bash "$RUN_BIN" --skill="$skill" --trigger=stop-hook || exit_aggregate=$?
  done
  exit "$exit_aggregate"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
