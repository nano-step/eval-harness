#!/usr/bin/env bash
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
RUN_BIN="$SCRIPT_DIR/run.sh"

usage() {
  cat <<EOF
eval-harness twotier — smoke then escalate-to-full on FAIL

Usage:
  twotier.sh --skill=<name> [--case=<id>] [--trigger=<name>]

Env:
  EVAL_SMOKE_MODEL        default: anthropic/claude-3-5-haiku-latest
  EVAL_SMOKE_SAMPLES      default: 1
  EVAL_FULL_MODEL         default: anthropic/claude-sonnet-4-6
  EVAL_FULL_SAMPLES       default: 3
EOF
}

ARGS=()
SKILL=""
CASE_ID=""
for arg in "$@"; do
  case "$arg" in
    --skill=*) SKILL="${arg#*=}"; ARGS+=("$arg") ;;
    --case=*)  CASE_ID="${arg#*=}"; ARGS+=("$arg") ;;
    -h|--help) usage; exit 0 ;;
    *) ARGS+=("$arg") ;;
  esac
done

if [[ -z "$SKILL" ]]; then
  echo "twotier: --skill=<name> required" >&2
  usage >&2
  exit 2
fi

STATE_DIR="${EVAL_STATE_DIR:-$HOME/.config/opencode/eval-harness}"

echo "[twotier] === SMOKE pass ==="
EVAL_MODE=smoke bash "$RUN_BIN" "${ARGS[@]}" --mode=smoke
smoke_rc=$?

SMOKE_RUN="$(ls -dt "$STATE_DIR/runs"/* 2>/dev/null | head -1 || true)"
if [[ -z "$SMOKE_RUN" || ! -f "$SMOKE_RUN/results.json" ]]; then
  echo "[twotier] smoke produced no results — bailing" >&2
  exit "$smoke_rc"
fi

smoke_verdict="$(jq -r '.verdict' "$SMOKE_RUN/results.json")"
if [[ "$smoke_verdict" == "PASS" ]]; then
  echo "[twotier] smoke PASS — no full pass needed."
  exit 0
fi

failed_cases="$(jq -r '[.cases[] | select(.passed == false) | .case_id] | join(",")' "$SMOKE_RUN/results.json")"
if [[ -z "$failed_cases" ]]; then
  echo "[twotier] no failed cases to escalate — exiting"
  exit "$smoke_rc"
fi

echo "[twotier] === FULL pass on failed cases: $failed_cases ==="

full_rc=0
IFS=',' read -ra cases_arr <<<"$failed_cases"
for c in "${cases_arr[@]}"; do
  EVAL_MODE=full bash "$RUN_BIN" --skill="$SKILL" --case="$c" --mode=full --trigger=2tier-escalation || full_rc=$?
done

if [[ "$full_rc" != "0" ]]; then
  echo "[twotier] FULL pass exited non-zero ($full_rc) — at least one case confirmed regression"
fi
exit "$full_rc"
