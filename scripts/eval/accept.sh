#!/usr/bin/env bash
# scripts/eval/accept.sh — accept new behavior as baseline.
# Settled Decision #14: two-stage acceptance.
#   default: updates checks/expected_outputs only, KEEPS old env_manifest (catches model drift)
#   --bless-env: also updates env_manifest, requires explicit confirmation prompt

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<EOF
Usage: eval-harness accept --skill=<name> --case=<id> [--bless-env] [--yes]

Without --bless-env (default):
  Updates checks/expected outputs in baseline.json. KEEPS old env_manifest so
  future model/opencode drift is still attributed cleanly.

With --bless-env:
  ALSO updates env_manifest. Future MODEL_CHANGED / OPENCODE_CHANGED attribution
  will use the current env as the new baseline. Requires confirmation.
EOF
}

SKILL=""; CASE_ID=""; BLESS_ENV=0; YES=0
for arg in "$@"; do
  case "$arg" in
    --skill=*)   SKILL="${arg#*=}" ;;
    --case=*)    CASE_ID="${arg#*=}" ;;
    --bless-env) BLESS_ENV=1 ;;
    --yes)       YES=1 ;;
    -h|--help)   usage; exit 0 ;;
    accept)      ;;
    *) echo "unknown arg: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -z "$SKILL" ]] || [[ -z "$CASE_ID" ]]; then
  echo "error: --skill and --case required" >&2; exit 2
fi

source "$(dirname "${BASH_SOURCE[0]}")/lib/skills_root.sh"
SKILLS_ROOT="$(resolve_skills_root)"
BASELINE_PATH="$SKILLS_ROOT/$SKILL/evals/baselines/$CASE_ID.baseline.json"

LATEST_RUN_DIR="$(ls -dt "${EVAL_STATE_DIR:-$HOME/.config/opencode/eval-harness}/runs"/* 2>/dev/null | head -1)"
if [[ -z "$LATEST_RUN_DIR" ]] || [[ ! -f "$LATEST_RUN_DIR/results.json" ]]; then
  echo "[eval-harness] accept: no recent run found. Run a case first." >&2
  exit 13
fi

NEW_CASE="$(jq --arg c "$CASE_ID" '.cases[] | select(.case_id == $c)' "$LATEST_RUN_DIR/results.json")"
if [[ -z "$NEW_CASE" ]]; then
  echo "[eval-harness] accept: case '$CASE_ID' not in latest run" >&2
  exit 2
fi

if [[ "$BLESS_ENV" == "1" ]] && [[ "$YES" != "1" ]]; then
  echo ""
  echo "WARNING: --bless-env will update env_manifest in:"
  echo "  $BASELINE_PATH"
  echo ""
  echo "Future runs against this baseline will treat the CURRENT model_id, opencode_version,"
  echo "and skill_bundle_sha as the new baseline. Silent model upgrades will not be flagged"
  echo "as MODEL_CHANGED until the next env change."
  echo ""
  read -r -p "Proceed? [y/N] " ans
  case "$ans" in
    y|Y|yes|YES) ;;
    *) echo "[eval-harness] aborted"; exit 1 ;;
  esac
fi

mkdir -p "$(dirname "$BASELINE_PATH")"

if [[ "$BLESS_ENV" == "1" ]]; then
  echo "$NEW_CASE" | jq '{
    schema_version: 2,
    case_id: .case_id,
    passed: .passed,
    checks: .checks,
    env_manifest: .env_manifest,
    last_seen_triggers: ["accept-bless-env"]
  }' > "$BASELINE_PATH"
  echo "[eval-harness] accepted (with env blessed): $BASELINE_PATH"
else
  # Keep old env_manifest if baseline existed; only update checks + expected outputs
  if [[ -f "$BASELINE_PATH" ]]; then
    OLD_MANIFEST="$(jq '.env_manifest' "$BASELINE_PATH")"
  else
    OLD_MANIFEST='{}'
  fi
  echo "$NEW_CASE" | jq --argjson old_env "$OLD_MANIFEST" '{
    schema_version: 2,
    case_id: .case_id,
    passed: .passed,
    checks: .checks,
    env_manifest: $old_env,
    last_seen_triggers: ["accept"]
  }' > "$BASELINE_PATH"
  echo "[eval-harness] accepted (env_manifest UNCHANGED): $BASELINE_PATH"
  echo "[eval-harness] use --bless-env to also update env_manifest"
fi
