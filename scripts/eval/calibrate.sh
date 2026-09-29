#!/usr/bin/env bash
# scripts/eval/calibrate.sh — measure the LLM judge against a human-labelled gold set (#EV-2a).
# Per-sample + cache-bypassing (so a rubric/prompt change isn't served stale) and uses the SAME
# system prompt as score_llm_judge (judge_system_prompt) — calibration must measure the real
# judge. Judge `null` is an ABSTAIN (third outcome), excluded from precision/recall/kappa
# denominators and reported as abstain_rate. Writes calibration.json (a level-2 validity metric,
# never results.json).

set -uo pipefail

_resolve_script_dir() {
  local src="${BASH_SOURCE[0]}"
  while [[ -L "$src" ]]; do local d; d="$(cd "$(dirname "$src")" && pwd)"; src="$(readlink "$src")"; [[ "$src" != /* ]] && src="$d/$src"; done
  cd "$(dirname "$src")" && pwd
}
SCRIPT_DIR="$(_resolve_script_dir)"
source "$SCRIPT_DIR/lib/yq-shim.sh"
source "$SCRIPT_DIR/lib/llm_judge.sh"
source "$SCRIPT_DIR/lib/stats.sh"
source "$SCRIPT_DIR/lib/skills_root.sh"
source "$SCRIPT_DIR/lib/portable.sh"

usage() {
  cat <<EOF
Usage: eval-harness calibrate --skill=<name> [--gold-dir=DIR] [--samples=N] [--out=FILE] [--check] [--estimate]

Measures the LLM judge against skills/<skill>/evals/gold/*.yaml (human-labelled).
  --check     Report readiness (kappa >= EVAL_CALIBRATION_MIN_KAPPA, default 0.6); never hard-exits.
  --estimate  Print projected judge-call count + cost and exit WITHOUT calling the API.
Env: EVAL_CALIBRATION_MIN_KAPPA (0.6), EVAL_CALIBRATION_BUDGET_USD (cap; refuse if estimate exceeds),
     EVAL_LLM_JUDGE_ARTIFACT_WINDOW (8000).
EOF
}

SKILL=""; GOLD_DIR=""; SAMPLES="${EVAL_CALIBRATION_SAMPLES:-1}"; OUT=""; CHECK=0; ESTIMATE=0
for arg in "$@"; do
  case "$arg" in
    --skill=*)    SKILL="${arg#*=}" ;;
    --gold-dir=*) GOLD_DIR="${arg#*=}" ;;
    --samples=*)  SAMPLES="${arg#*=}" ;;
    --out=*)      OUT="${arg#*=}" ;;
    --check)      CHECK=1 ;;
    --estimate)   ESTIMATE=1 ;;
    -h|--help)    usage; exit 0 ;;
    calibrate)    ;;
    *) echo "unknown arg: $arg" >&2; usage >&2; exit 2 ;;
  esac
done
[[ "$SAMPLES" =~ ^[1-9][0-9]*$ ]] || SAMPLES=1

if [[ -z "$GOLD_DIR" ]]; then
  [[ -z "$SKILL" ]] && { echo "error: --skill or --gold-dir required" >&2; exit 2; }
  GOLD_DIR="$(resolve_skills_root)/$SKILL/evals/gold"
fi
[[ -d "$GOLD_DIR" ]] || { echo "[eval-harness] calibrate: gold dir not found: $GOLD_DIR" >&2; exit 2; }

GOLD_FILES=()
while IFS= read -r _gold_file; do
  [[ -n "$_gold_file" ]] && GOLD_FILES+=("$_gold_file")
done < <(find "$GOLD_DIR" -maxdepth 1 -type f -name '*.yaml' | sort)
n_entries=${#GOLD_FILES[@]}
[[ "$n_entries" -eq 0 ]] && { echo "[eval-harness] calibrate: no gold entries in $GOLD_DIR" >&2; exit 2; }

gold_set_version="$(yq -r '.gold_set_version // 1' "$GOLD_DIR/manifest.json" 2>/dev/null || echo 1)"
judge_model="${EVAL_LLM_JUDGE_MODEL:-anthropic/claude-sonnet-4-6}"
artifact_window="${EVAL_LLM_JUDGE_ARTIFACT_WINDOW:-8000}"
prompt_sha="$(judge_system_prompt | portable_sha256_stdin | cut -d' ' -f1)"
projected_calls=$(( n_entries * SAMPLES ))

# --estimate: project cost, make NO API calls.
if [[ "$ESTIMATE" == "1" ]]; then
  est_usd="$(jq -nc --argjson calls "$projected_calls" '($calls * 0.003)')"   # ~rough: $0.003/judge call
  echo "[eval-harness] calibrate --estimate: $n_entries gold entries x $SAMPLES samples = $projected_calls judge calls (~\$$est_usd)"
  exit 0
fi

# Separate bursty budget guard (distinct from the daily run ledger).
if [[ -n "${EVAL_CALIBRATION_BUDGET_USD:-}" ]]; then
  est_usd="$(jq -nc --argjson calls "$projected_calls" '($calls * 0.003)')"
  if awk -v a="$est_usd" -v b="$EVAL_CALIBRATION_BUDGET_USD" 'BEGIN{exit !(a+0 > b+0)}'; then
    echo "[eval-harness] calibrate: projected ~\$$est_usd exceeds EVAL_CALIBRATION_BUDGET_USD=$EVAL_CALIBRATION_BUDGET_USD — refusing. Use --estimate to inspect." >&2
    exit 13
  fi
fi

tp=0; fp=0; tn=0; fn=0; abstain=0; per_entry="[]"
for gf in "${GOLD_FILES[@]}"; do
  id="$(yq -r '.id' "$gf")"
  rubric="$(yq -r '.rubric' "$gf")"
  human="$(yq -r '.human_verdict' "$gf" | tr '[:lower:]' '[:upper:]')"
  artifact="$(yq -r '.artifact // ""' "$gf")"
  af="$(yq -r '.artifact_file // ""' "$gf")"
  if [[ -n "$af" ]]; then
    # Reuse the fixture-style traversal guard: reject absolute / '..'.
    if [[ "$af" = /* || "$af" == *..* ]]; then echo "[calibrate] $id: rejecting unsafe artifact_file '$af'" >&2; continue; fi
    [[ -f "$GOLD_DIR/$af" ]] && artifact="$(head -c "$artifact_window" "$GOLD_DIR/$af")"
  fi
  user_prompt="$(printf 'RUBRIC:\n%s\n\nARTIFACT:\n%s' "$rubric" "$artifact")"
  result="$(EVAL_LLM_JUDGE_NO_CACHE=1 llm_judge_majority "$judge_model" "$(judge_system_prompt)" "$user_prompt" "$SAMPLES")"
  jv="$(echo "$result" | jq -r '.majority_verdict // "null"')"

  cls=""
  if [[ "$jv" == "null" ]]; then abstain=$((abstain+1)); cls="abstain"
  elif [[ "$human" == "PASS" && "$jv" == "PASS" ]]; then tp=$((tp+1)); cls="tp"
  elif [[ "$human" == "FAIL" && "$jv" == "FAIL" ]]; then tn=$((tn+1)); cls="tn"
  elif [[ "$human" == "FAIL" && "$jv" == "PASS" ]]; then fp=$((fp+1)); cls="fp"
  elif [[ "$human" == "PASS" && "$jv" == "FAIL" ]]; then fn=$((fn+1)); cls="fn"
  fi
  per_entry="$(echo "$per_entry" | jq --arg id "$id" --arg h "$human" --arg j "$jv" --arg c "$cls" \
    '. + [{id:$id, human:$h, judge:$j, class:$c}]')"
done

kappa="$(cohen_kappa "$tp" "$fp" "$tn" "$fn")"
calibration_json="$(jq -n \
  --argjson tp "$tp" --argjson fp "$fp" --argjson tn "$tn" --argjson fn "$fn" --argjson ab "$abstain" \
  --argjson total "$n_entries" --argjson samples "$SAMPLES" --argjson gv "$gold_set_version" \
  --arg model "$judge_model" --arg psha "$prompt_sha" --argjson window "$artifact_window" \
  --argjson kappa "${kappa:-null}" --argjson entries "$per_entry" --arg ts "$(date -u +%FT%TZ)" '
  ($tp + $fp + $tn + $fn) as $decided
  | {
      schema_version: 1, kind: "calibration", computed_at: $ts,
      gold_set_version: $gv, judge_model: $model, judge_prompt_sha: $psha,
      artifact_window: $window, samples: $samples,
      matrix: {tp:$tp, fp:$fp, tn:$tn, fn:$fn, abstain:$ab},
      precision: (if ($tp+$fp)>0 then ($tp/($tp+$fp)) else null end),
      recall:    (if ($tp+$fn)>0 then ($tp/($tp+$fn)) else null end),
      agreement: (if $decided>0 then (($tp+$tn)/$decided) else null end),
      kappa: $kappa,
      abstain_rate: (if $total>0 then ($ab/$total) else null end),
      entries: $entries
    }')"

[[ -n "$OUT" ]] && { mkdir -p "$(dirname "$OUT")" 2>/dev/null || true; echo "$calibration_json" > "$OUT"; }

if [[ "$CHECK" == "1" ]]; then
  min_k="${EVAL_CALIBRATION_MIN_KAPPA:-0.6}"
  echo "[eval-harness] calibrate --check (gold v$gold_set_version, $n_entries entries):"
  echo "$calibration_json" | jq -r '"  precision=\(.precision) recall=\(.recall) agreement=\(.agreement) kappa=\(.kappa) abstain_rate=\(.abstain_rate)"'
  k="$(echo "$calibration_json" | jq -r '.kappa // -1')"
  if awk -v a="$k" -v b="$min_k" 'BEGIN{exit !(a+0 >= b+0)}'; then
    echo "  ready: kappa >= $min_k — judge calibrated for this skill"
  else
    echo "  not ready: kappa ($k) < $min_k"
  fi
  exit 0
fi

echo "$calibration_json"
exit 0
