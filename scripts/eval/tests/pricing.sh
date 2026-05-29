#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d -t eval-harness-price.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

PRICING="$SCRIPT_DIR/../lib/pricing.sh"

cost="$(bash "$PRICING" cost anthropic/claude-3-5-haiku-latest 1000000 1000000)"
usd="$(echo "$cost" | jq -r '.usd')"
[[ "$usd" == "6" || "$usd" == "6.0" || "$usd" == "6.000000" ]] || \
  { echo "FAIL: 1M in + 1M out at \$1/\$5 = \$6, got $usd" >&2; echo "$cost" >&2; exit 1; }

cost="$(bash "$PRICING" cost anthropic/claude-sonnet-4-6 100000 50000)"
usd="$(echo "$cost" | jq -r '.usd')"
[[ "$usd" == "1.05" ]] || \
  { echo "FAIL: 100k in + 50k out at sonnet rates should be \$1.05, got $usd" >&2; echo "$cost" >&2; exit 1; }

cost="$(bash "$PRICING" cost anthropic/no-such-model 1000 1000)"
reason="$(echo "$cost" | jq -r '.reason')"
[[ "$reason" == "unknown_model:anthropic/no-such-model" ]] || \
  { echo "FAIL: unknown model should yield reason, got '$reason'" >&2; exit 1; }

cat > "$WORK/fresh.json" <<JSON
{"schema_version": 1, "as_of": "$(date -u +%F)", "stale_after_days": 60, "models": {}}
JSON
EVAL_PRICING_FILE="$WORK/fresh.json" bash "$PRICING" staleness | jq -e '.status == "FRESH"' >/dev/null \
  || { echo "FAIL: today should be FRESH" >&2; exit 1; }

cat > "$WORK/stale.json" <<JSON
{"schema_version": 1, "as_of": "2020-01-01", "stale_after_days": 60, "models": {}}
JSON
EVAL_PRICING_FILE="$WORK/stale.json" bash "$PRICING" staleness | jq -e '.status == "STALE"' >/dev/null \
  || { echo "FAIL: 2020-01-01 should be STALE" >&2; exit 1; }

EVAL_PRICING_FILE="$WORK/nonexistent.json" bash "$PRICING" staleness | jq -e '.status == "MISSING"' >/dev/null \
  || { echo "FAIL: nonexistent file should be MISSING" >&2; exit 1; }

cat > "$WORK/transcript.jsonl" <<'JSONL'
{"event":"assistant_message","usage":{"input_tokens":1500,"output_tokens":500}}
{"event":"assistant_message","usage":{"input_tokens":2000,"output_tokens":1000}}
JSONL
toks="$(bash "$PRICING" tokens "$WORK/transcript.jsonl")"
[[ "$toks" == "3500 1500" ]] || { echo "FAIL: token sum expected '3500 1500', got '$toks'" >&2; exit 1; }

echo "PASS: pricing.sh — cost / staleness / token-extraction all correct"
exit 0
