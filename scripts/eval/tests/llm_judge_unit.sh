#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d -t eval-harness-judge.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

STUB_BIN="$WORK/bin"
mkdir -p "$STUB_BIN"

cat > "$STUB_BIN/curl" <<'STUB'
#!/usr/bin/env bash
verdict="${TEST_JUDGE_VERDICT:-PASS}"
case "$verdict" in
  PASS|FAIL)
    cat <<JSON
{"id":"msg_x","type":"message","role":"assistant","content":[{"type":"text","text":"$verdict\nlooks good"}],"stop_reason":"end_turn"}
JSON
    ;;
  ERROR)
    cat <<JSON
{"type":"error","error":{"type":"api_error","message":"simulated_failure"}}
JSON
    ;;
esac
exit 0
STUB
chmod +x "$STUB_BIN/curl"
export PATH="$STUB_BIN:$PATH"
export ANTHROPIC_API_KEY="sk-ant-AAAAAAAAAAAAAAAAAAAAAA"

source "$SCRIPT_DIR/../lib/yq-shim.sh"
source "$SCRIPT_DIR/../lib/llm_judge.sh"

export TEST_JUDGE_VERDICT=PASS
out="$(llm_judge_call_once anthropic/claude-sonnet-4-6 sys 'user msg')"
v="$(echo "$out" | jq -r '.verdict')"
[[ "$v" == "PASS" ]] || { echo "FAIL: single PASS verdict, got '$v'" >&2; echo "$out" >&2; exit 1; }

export TEST_JUDGE_VERDICT=FAIL
out="$(llm_judge_call_once anthropic/claude-sonnet-4-6 sys 'user msg')"
v="$(echo "$out" | jq -r '.verdict')"
[[ "$v" == "FAIL" ]] || { echo "FAIL: single FAIL verdict, got '$v'" >&2; echo "$out" >&2; exit 1; }

export TEST_JUDGE_VERDICT=PASS
out="$(llm_judge_majority anthropic/claude-sonnet-4-6 sys user 3)"
mv="$(echo "$out" | jq -r '.majority_verdict')"
pc="$(echo "$out" | jq -r '.pass_count')"
[[ "$mv" == "PASS" && "$pc" == "3" ]] || { echo "FAIL: 3-of-3 PASS expected majority=PASS, got mv='$mv' pc=$pc" >&2; echo "$out" >&2; exit 1; }

export TEST_JUDGE_VERDICT=ERROR
out="$(llm_judge_majority anthropic/claude-sonnet-4-6 sys user 3)"
mv="$(echo "$out" | jq -r '.majority_verdict')"
nc="$(echo "$out" | jq -r '.null_count')"
[[ "$mv" == "null" && "$nc" == "3" ]] || { echo "FAIL: 3 errors expected majority=null nulls=3, got mv='$mv' nc=$nc" >&2; echo "$out" >&2; exit 1; }

unset ANTHROPIC_API_KEY
out="$(llm_judge_call_once anthropic/claude-sonnet-4-6 sys 'user msg')"
v="$(echo "$out" | jq -r '.verdict')"
r="$(echo "$out" | jq -r '.reason')"
[[ "$v" == "null" ]] || { echo "FAIL: no api key should yield verdict=null, got '$v'" >&2; exit 1; }
[[ "$r" == *"ANTHROPIC_API_KEY"* ]] || { echo "FAIL: reason should mention ANTHROPIC_API_KEY, got '$r'" >&2; exit 1; }

echo "PASS: llm_judge unit — PASS/FAIL/ERROR + 3-sample majority + missing-key fallback all correct"
exit 0
