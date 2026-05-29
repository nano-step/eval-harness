#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

WORK="$(mktemp -d -t eval-harness-2tier.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

export OPENCODE_SKILLS_ROOT="$WORK/skills"
export EVAL_STATE_DIR="$WORK/state"
export EVAL_SKIP_AUTH_CHECK=1
mkdir -p "$OPENCODE_SKILLS_ROOT" "$EVAL_STATE_DIR"
cp -R "$REPO_ROOT/skills/omo-session-distiller" "$OPENCODE_SKILLS_ROOT/"

STUB_BIN="$WORK/bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/opencode" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then echo "1.15.10-stub"; exit 0; fi
cwd="$(pwd)"
while [[ $# -gt 0 ]]; do
  case "$1" in --dir) cwd="$2"; shift 2 ;; --dir=*) cwd="${1#*=}"; shift ;; *) shift ;; esac
done
cd "$cwd"
export PATH="$cwd:$PATH"
export NANO_BRAIN_SHIM_STORE="$cwd/nano-brain-store.json"
npx nano-brain write -c k --content "Postgres choice" --tags "decision,architecture" >/dev/null
echo "{}"
exit 0
STUB
chmod +x "$STUB_BIN/opencode"
export PATH="$STUB_BIN:$PATH"

bash "$REPO_ROOT/scripts/eval/run.sh" --skill=omo-session-distiller --case=atom-tags-decision-architecture --mode=smoke > "$WORK/smoke.log" 2>&1 || true

SMOKE_RUN="$(ls -dt "$EVAL_STATE_DIR/runs"/* | head -1)"
SMOKE_MODEL="$(jq -r '.cases[0].env_manifest.model_id' "$SMOKE_RUN/results.json")"
[[ "$SMOKE_MODEL" == "anthropic/claude-3-5-haiku-latest" ]] || \
  { echo "FAIL: smoke mode should pin haiku model, got '$SMOKE_MODEL'" >&2; exit 1; }

bash "$REPO_ROOT/scripts/eval/run.sh" --skill=omo-session-distiller --case=atom-tags-decision-architecture --mode=full > "$WORK/full.log" 2>&1 || true
FULL_RUN="$(ls -dt "$EVAL_STATE_DIR/runs"/* | head -1)"
FULL_MODEL="$(jq -r '.cases[0].env_manifest.model_id' "$FULL_RUN/results.json")"
[[ "$FULL_MODEL" == "anthropic/claude-sonnet-4-6" ]] || \
  { echo "FAIL: full mode should pin sonnet-4-6, got '$FULL_MODEL'" >&2; exit 1; }

bash "$REPO_ROOT/scripts/eval/run.sh" --skill=omo-session-distiller --case=atom-tags-decision-architecture --mode=2tier > "$WORK/2tier.log" 2>&1 || true
grep -q "SMOKE pass" "$WORK/2tier.log" || { echo "FAIL: 2tier mode did not run SMOKE pass" >&2; cat "$WORK/2tier.log" >&2; exit 1; }

bash "$REPO_ROOT/scripts/eval/run.sh" --mode=invalid --skill=omo-session-distiller > "$WORK/inv.log" 2>&1 && \
  { echo "FAIL: invalid mode should have exited 2" >&2; exit 1; } || true
grep -q "invalid --mode" "$WORK/inv.log" || { echo "FAIL: missing invalid-mode error" >&2; cat "$WORK/inv.log" >&2; exit 1; }

echo "PASS: 2tier mode — smoke pins haiku, full pins sonnet, 2tier orchestrates, invalid rejected"
exit 0
