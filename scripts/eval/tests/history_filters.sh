#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
STATE="$TMP/state"
mkdir -p "$STATE/runs/run-alpha" "$STATE/runs/run-beta"
cat > "$STATE/runs/run-alpha/results.json" <<'JSON'
{"schema_version":3,"run_id":"run-alpha","trigger":"manual","verdict":"PASS","summary":{"pass":1,"total":1},"cases":[{"case_id":"a","env_manifest":{"skill_under_test":"alpha"}}]}
JSON
printf 'alpha-diff\n' > "$STATE/runs/run-alpha/diff.md"
cat > "$STATE/runs/run-beta/results.json" <<'JSON'
{"schema_version":3,"run_id":"run-beta","trigger":"manual","verdict":"FAIL","summary":{"pass":0,"total":1},"cases":[{"case_id":"b","env_manifest":{"skill_under_test":"beta"}}]}
JSON
printf 'beta-diff\n' > "$STATE/runs/run-beta/diff.md"
printf '%s\n' \
  '{"event":"run","run_id":"run-alpha","skill":"alpha","trigger":"manual","verdict":"PASS","summary":{"pass":1,"total":1}}' \
  '{"event":"run","run_id":"run-beta","skill":"beta","trigger":"manual","verdict":"FAIL","summary":{"pass":0,"total":1}}' > "$STATE/history.ndjson"

status_alpha="$(EVAL_STATE_DIR="$STATE" bash "$SCRIPT_DIR/status.sh" --skill=alpha)"
[[ "$status_alpha" == *run-alpha* && "$status_alpha" != *run-beta* ]]
latest_beta="$(EVAL_STATE_DIR="$STATE" bash "$SCRIPT_DIR/status.sh" --latest --skill=beta)"
[[ "$latest_beta" == *beta-diff* && "$latest_beta" != *alpha-diff* ]]
trend_alpha="$(EVAL_STATE_DIR="$STATE" bash "$SCRIPT_DIR/trend.sh" --skill=alpha --last=5)"
[[ "$trend_alpha" == *run-alpha* && "$trend_alpha" != *run-beta* ]]
trend_beta="$(EVAL_STATE_DIR="$STATE" bash "$SCRIPT_DIR/trend.sh" --skill=beta --last=1)"
[[ "$trend_beta" == *run-beta* && "$trend_beta" != *run-alpha* ]]
echo 'PASS status and trend honor skill filters and exact latest result selection'
