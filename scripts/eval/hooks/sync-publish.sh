#!/usr/bin/env bash
# eval-harness pre-publish hook for sync-skill-to-manager.
# Settled Decision #3: full suite, sync, blocking. Carried verbatim from v1 brief.
# eval-harness itself is whitelisted (Settled #3 prior brief: avoid bootstrap deadlock).

set -euo pipefail

SKILL="${1:-}"
if [[ -z "$SKILL" ]]; then
  echo "[eval-harness] sync-publish: usage: sync-publish.sh <skill-name>" >&2
  exit 2
fi

# Whitelist: eval-harness itself never gates its own publish
if [[ "$SKILL" == "eval-harness" ]]; then
  echo "[eval-harness] sync-publish: skipping (eval-harness is self-whitelisted)" >&2
  exit 0
fi

# Opt-in gate: only run if skill has evals.required: true in skill.yaml
source "$(dirname "${BASH_SOURCE[0]}")/../lib/skills_root.sh"
SKILLS_ROOT="$(resolve_skills_root)"
SKILL_META="$SKILLS_ROOT/$SKILL/skill.yaml"

if [[ -f "$SKILL_META" ]]; then
  required="$(yq -r '.evals.required // false' "$SKILL_META" 2>/dev/null || echo false)"
  if [[ "$required" != "true" ]]; then
    echo "[eval-harness] sync-publish: '$SKILL' has not opted into the gate (evals.required != true)" >&2
    exit 0
  fi
fi

EVAL_HARNESS_BIN="${EVAL_HARNESS_BIN:-eval-harness}"
"$EVAL_HARNESS_BIN" --skill="$SKILL" --trigger=sync-publish
