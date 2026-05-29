#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

WORK="$(mktemp -d -t eval-harness-stable.XXXXXX)"
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
exit 0
STUB
chmod +x "$STUB_BIN/opencode"
export PATH="$STUB_BIN:$PATH"

bash "$REPO_ROOT/scripts/eval/run.sh" \
  --skill=omo-session-distiller \
  --case=atom-shape-basic \
  --stability-samples=3 \
  --trigger=manual >"$WORK/out.log" 2>&1 || true

LATEST="$(ls -dt "$EVAL_STATE_DIR/runs"/* | head -1)"
STAB="$LATEST/atom-shape-basic/stability.json"
if [[ ! -f "$STAB" ]]; then
  echo "FAIL: stability.json not produced at $STAB" >&2
  cat "$WORK/out.log" >&2
  exit 1
fi

SAMPLES="$(jq -r '.samples' "$STAB")"
PERFORMED="$(jq -r '.performed' "$STAB")"
IDENTICAL="$(jq -r '.byte_identical' "$STAB")"
N_HASHES="$(jq -r '.hashes | length' "$STAB")"

[[ "$SAMPLES" == "3" ]] || { echo "FAIL: samples=$SAMPLES, expected 3" >&2; exit 1; }
[[ "$PERFORMED" == "true" ]] || { echo "FAIL: performed=$PERFORMED, expected true" >&2; exit 1; }
[[ "$IDENTICAL" == "true" ]] || { echo "FAIL: byte_identical=$IDENTICAL, expected true (deterministic stub)" >&2; cat "$STAB" >&2; exit 1; }
[[ "$N_HASHES" == "3" ]] || { echo "FAIL: hashes len=$N_HASHES, expected 3" >&2; exit 1; }

CASE_RESULT="$(jq '.cases[0]' "$LATEST/results.json")"
RESULT_SAMPLES="$(echo "$CASE_RESULT" | jq -r '.stability.samples')"
[[ "$RESULT_SAMPLES" == "3" ]] || { echo "FAIL: results.cases[0].stability.samples=$RESULT_SAMPLES" >&2; exit 1; }

echo "PASS: 3-sample stability: deterministic stub yielded byte-identical across all 3 samples"
exit 0
