#!/usr/bin/env bash
set -euo pipefail

_PRICING_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

resolve_pricing_file() {
  if [[ -n "${EVAL_PRICING_FILE:-}" ]]; then
    if [[ -f "${EVAL_PRICING_FILE}" ]]; then
      printf '%s\n' "${EVAL_PRICING_FILE}"
      return 0
    fi
    return 1
  fi
  for candidate in \
      "$_PRICING_DIR/../../../pricing.json" \
      "$_PRICING_DIR/../../pricing.json" \
      "$HOME/.config/opencode/eval-harness/pricing.json"; do
    if [[ -f "$candidate" ]]; then
      printf '%s\n' "$(cd "$(dirname "$candidate")" && pwd)/$(basename "$candidate")"
      return 0
    fi
  done
  return 1
}

pricing_staleness_check() {
  local pricing_file
  pricing_file="$(resolve_pricing_file)" || {
    echo '{"status": "MISSING", "message": "no pricing.json found"}'
    return 0
  }
  local as_of stale_after_days today_epoch as_of_epoch days_old
  as_of="$(jq -r '.as_of' "$pricing_file")"
  stale_after_days="$(jq -r '.stale_after_days // 60' "$pricing_file")"
  today_epoch="$(date -u +%s)"
  if as_of_epoch="$(date -u -d "$as_of" +%s 2>/dev/null)"; then :
  elif as_of_epoch="$(date -j -f "%Y-%m-%d" "$as_of" +%s 2>/dev/null)"; then :
  else
    echo "{\"status\": \"INVALID\", \"message\": \"unparseable as_of '$as_of'\"}"
    return 0
  fi
  days_old=$(( (today_epoch - as_of_epoch) / 86400 ))
  if [[ "$days_old" -gt "$stale_after_days" ]]; then
    jq -n --arg af "$as_of" --arg d "$days_old" --arg t "$stale_after_days" \
      '{status: "STALE", as_of: $af, days_old: ($d|tonumber), stale_after_days: ($t|tonumber), message: ("pricing data " + $d + " days old (limit " + $t + ")")}'
  else
    jq -n --arg af "$as_of" --arg d "$days_old" \
      '{status: "FRESH", as_of: $af, days_old: ($d|tonumber)}'
  fi
}

compute_cost_usd() {
  local model_id="$1"
  local input_tokens="${2:-0}"
  local output_tokens="${3:-0}"
  local pricing_file
  pricing_file="$(resolve_pricing_file)" || {
    echo '{"usd": null, "reason": "no pricing.json"}'
    return 0
  }
  local has_model
  has_model="$(jq -r --arg m "$model_id" '.models[$m] != null' "$pricing_file")"
  if [[ "$has_model" != "true" ]]; then
    echo "{\"usd\": null, \"reason\": \"unknown_model:$model_id\"}"
    return 0
  fi

  jq -n \
    --arg model "$model_id" \
    --argjson in_toks "$input_tokens" \
    --argjson out_toks "$output_tokens" \
    --slurpfile p "$pricing_file" \
    '
    ($p[0].models[$model]) as $rates
    | ($in_toks * $rates.input_per_mtok_usd / 1000000) as $in_cost
    | ($out_toks * $rates.output_per_mtok_usd / 1000000) as $out_cost
    | {
        usd: (($in_cost + $out_cost) * 1000000 | floor / 1000000),
        input_tokens: $in_toks,
        output_tokens: $out_toks,
        input_per_mtok_usd: $rates.input_per_mtok_usd,
        output_per_mtok_usd: $rates.output_per_mtok_usd
      }
    '
}

tokens_from_transcript() {
  local transcript="$1"
  if [[ ! -s "$transcript" ]]; then
    echo "0 0"; return 0
  fi
  local in_t out_t
  in_t="$(jq -s '[.[] | .. | objects | .usage? | .input_tokens? // .prompt_tokens? // empty] | add // 0' "$transcript" 2>/dev/null || echo 0)"
  out_t="$(jq -s '[.[] | .. | objects | .usage? | .output_tokens? // .completion_tokens? // empty] | add // 0' "$transcript" 2>/dev/null || echo 0)"
  echo "$in_t $out_t"
}

export -f resolve_pricing_file pricing_staleness_check compute_cost_usd tokens_from_transcript

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  case "${1:-}" in
    resolve)    resolve_pricing_file ;;
    staleness)  pricing_staleness_check ;;
    cost)       shift; compute_cost_usd "$@" ;;
    tokens)     shift; tokens_from_transcript "$@" ;;
    *) echo "usage: pricing.sh {resolve|staleness|cost <model> <in_tok> <out_tok>|tokens <transcript>}" >&2; exit 2 ;;
  esac
fi
