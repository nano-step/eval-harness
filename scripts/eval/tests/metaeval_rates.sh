#!/usr/bin/env bash
# Regression test for EV-1: metaeval measures the harness's own FP/FN/attribution accuracy
# over a corpus with real denominators (>1), and the harness scores perfectly on it today.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
EMPTY_CORPUS="$WORK/empty-corpus"
mkdir -p "$EMPTY_CORPUS"
if EVAL_METAEVAL_ALLOW_REAL=1 bash "$REPO_ROOT/scripts/eval/metaeval.sh" --corpus="$EMPTY_CORPUS" --out="$WORK/empty.json" >/dev/null 2>&1; then
  echo "FAIL: empty metaeval corpus reported success" >&2
  exit 1
fi
[[ ! -e "$WORK/empty.json" ]] || { echo "FAIL: empty metaeval corpus wrote a result" >&2; exit 1; }

# metaeval drives stub-only; a real opencode on PATH would (correctly) make it abort, so this
# test relies on the test environment having no real opencode binary (CI runners / harness do not).
if command -v opencode >/dev/null 2>&1; then
  echo "PASS (skipped): a real opencode is on PATH; metaeval rate-measurement needs a stub-only env" ; exit 0
fi

OUT="$WORK/metaeval.json"
bash "$REPO_ROOT/scripts/eval/metaeval.sh" --out="$OUT" >/dev/null 2>&1 || true
jq -e . "$OUT" >/dev/null 2>&1 || { echo "FAIL: metaeval.json invalid" >&2; cat "$OUT" >&2; exit 1; }
jq -e 'all(.entries[]; .mutation_applied == true)' "$OUT" >/dev/null \
  || { echo "FAIL: metaeval counted a scenario without applying its mutation" >&2; jq '.entries' "$OUT" >&2; exit 1; }
jq -e '.entries | any(.[]; .mutation == "benign_whitespace" and .mutation_applied == true)' "$OUT" >/dev/null \
  || { echo "FAIL: whitespace scenario did not mutate its skill input" >&2; jq '.entries' "$OUT" >&2; exit 1; }

nr="$(jq -r '.summary.regressions' "$OUT")"
nb="$(jq -r '.summary.benign' "$OUT")"
fn="$(jq -r '.summary.false_negatives' "$OUT")"
fp="$(jq -r '.summary.false_positives' "$OUT")"
aa="$(jq -r '.summary.attribution_accuracy' "$OUT")"

# Denominators must be > 1 (the whole point — regression_inject's N=1 is not a validity claim).
[[ "$nr" -ge 3 ]] || { echo "FAIL: need >=3 regression entries, got $nr" >&2; exit 1; }
[[ "$nb" -ge 2 ]] || { echo "FAIL: need >=2 benign entries, got $nb" >&2; exit 1; }
# The harness must catch every regression, flag no benign edit, and attribute all correctly.
[[ "$fn" -eq 0 ]] || { echo "FAIL: false negatives = $fn (missed a real regression)" >&2; jq '.entries' "$OUT" >&2; exit 1; }
[[ "$fp" -eq 0 ]] || { echo "FAIL: false positives = $fp (flagged a benign edit)" >&2; jq '.entries' "$OUT" >&2; exit 1; }
awk -v a="$aa" 'BEGIN{exit !(a+0 >= 0.999)}' || { echo "FAIL: attribution_accuracy=$aa (expected 1.0)" >&2; jq '.entries' "$OUT" >&2; exit 1; }

echo "PASS: metaeval — FN=$fn/$nr FP=$fp/$nb attribution_accuracy=$aa (denominators > 1)"
exit 0
