#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

WORK="$(mktemp -d -t eval-harness-model.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

export OPENCODE_SKILLS_ROOT="$WORK/skills"
export EVAL_STATE_DIR="$WORK/state"
export EVAL_SKIP_AUTH_CHECK=1
mkdir -p "$OPENCODE_SKILLS_ROOT/foo/evals/cases"

cat > "$OPENCODE_SKILLS_ROOT/foo/evals/cases/m1.yaml" <<YAML
schema_version: 2
id: m1
mode: deterministic
skill_under_test: foo
skills_loaded: [foo]
description: model override smoke test
model: anthropic/claude-opus-4-7
prompt: noop
budget: { max_tokens: 1000, max_seconds: 10 }
checks:
  - kind: file_exists
    path: nonexistent
YAML

STUB_BIN="$WORK/bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/opencode" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then echo "1.15.10-stub"; exit 0; fi
echo "stub-model-record: model=${EVAL_CASE_MODEL:-NOT_SET}" > "$WORK_RECORD/observed-model.txt"
exit 0
STUB
chmod +x "$STUB_BIN/opencode"
export WORK_RECORD="$WORK"
export PATH="$STUB_BIN:$PATH"

bash "$SCRIPT_DIR/../run.sh" --skill=foo --case=m1 --trigger=manual >"$WORK/out.log" 2>&1 || true

LATEST_RUN="$(ls -dt "$EVAL_STATE_DIR/runs"/* | head -1)"
MANIFEST="$LATEST_RUN/m1/env-manifest.json"
if [[ ! -f "$MANIFEST" ]]; then
  echo "FAIL: env-manifest.json not produced at $MANIFEST" >&2
  cat "$WORK/out.log" >&2
  exit 1
fi

RECORDED_MODEL="$(jq -r '.model_id' "$MANIFEST")"
if [[ "$RECORDED_MODEL" != "anthropic/claude-opus-4-7" ]]; then
  echo "FAIL: expected manifest.model_id=anthropic/claude-opus-4-7, got '$RECORDED_MODEL'" >&2
  exit 1
fi

echo "PASS: per-case model override surfaced into env-manifest as '$RECORDED_MODEL'"
exit 0
