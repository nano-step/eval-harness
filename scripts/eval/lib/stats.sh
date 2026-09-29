#!/usr/bin/env bash
# lib/stats.sh — statistics for the evaluation-validity layer, computed in pure jq (jq has
# `sqrt` and arithmetic — no bc, no python, portable across macOS/Linux). (#EV-W, #EV-2a)

set -euo pipefail

# wilson_interval <pass> <n> [z]  ->  {lower, upper, z}
# Uncorrected Wilson score interval for a binomial proportion (right for small n and
# p-near-edge, where Wald is wrong and Clopper-Pearson would need lgamma->python).
# Bounds clamped to [0,1]; n=0 -> {0,1} (no samples, no information). z default 1.96 (95%).
wilson_interval() {
  local pass="$1" n="$2" z="${3:-1.96}"
  jq -n --argjson pass "$pass" --argjson n "$n" --argjson z "$z" '
    def clamp: if . < 0 then 0 elif . > 1 then 1 else . end;
    if $n == 0 then {lower: 0, upper: 1, z: $z}
    else
      ($pass / $n) as $p
      | ($z * $z) as $z2
      | (1 + $z2 / $n) as $denom
      | (($p + $z2 / (2 * $n)) / $denom) as $center
      | (($z * ((($p * (1 - $p) / $n) + ($z2 / (4 * $n * $n))) | sqrt)) / $denom) as $margin
      | {lower: (($center - $margin) | clamp), upper: (($center + $margin) | clamp), z: $z}
    end'
}

# cohen_kappa <tp> <fp> <tn> <fn>  ->  number (kappa over the 2x2 decided matrix) or "null"
# p_o = (TP+TN)/N ; p_e = ((TP+FP)(TP+FN) + (FN+TN)(FP+TN))/N^2 ; kappa = (p_o-p_e)/(1-p_e)
cohen_kappa() {
  local tp="$1" fp="$2" tn="$3" fn="$4"
  jq -n --argjson tp "$tp" --argjson fp "$fp" --argjson tn "$tn" --argjson fn "$fn" '
    ($tp + $fp + $tn + $fn) as $N
    | if $N == 0 then null
      else
        (($tp + $tn) / $N) as $po
        | (((($tp + $fp) * ($tp + $fn)) + (($fn + $tn) * ($fp + $tn))) / ($N * $N)) as $pe
        | if (1 - $pe) == 0 then null else (($po - $pe) / (1 - $pe)) end
      end'
}

# reliability_metrics <successes> <attempts> <k> [z]
# Plug-in IID estimates for one fixed case/configuration, with Wilson intervals for p
# transformed monotonically to pass@k and pass^k. Conditional failure-stability reruns
# are not part of this sampling frame.
reliability_metrics() {
  local successes="$1" attempts="$2" k="$3" z="1.96"
  [[ $# -ge 4 ]] && z="$4"
  local interval
  interval="$(wilson_interval "$successes" "$attempts" "$z")"
  jq -n --argjson x "$successes" --argjson n "$attempts" --argjson k "$k" \
    --argjson ci "$interval" '
    def power($p; $k): reduce range(0; $k) as $i (1; . * $p);
    if $n == 0 then {
      status:"unavailable", successes:$x, attempts:$n, k:$k,
      success_rate:null, pass_at_k:null, pass_power_k:null,
      wilson:$ci, pass_at_k_interval:null, pass_power_k_interval:null,
      sampling_assumption:"IID attempts of the same case/configuration; not empirically verified"
    }
    elif $x < 0 or $x > $n or $k < 1 or $k != ($k|floor) or $k > $n then {
      status:"invalid", successes:$x, attempts:$n, k:$k,
      success_rate:null, pass_at_k:null, pass_power_k:null,
      wilson:$ci, pass_at_k_interval:null, pass_power_k_interval:null,
      sampling_assumption:"k must be an integer in [1,n] and successes must be in [0,n]"
    }
    else
      ($x / $n) as $p
      | {
          status:"available", successes:$x, attempts:$n, k:$k,
          success_rate:$p,
          pass_at_k:(1 - power((1 - $p); $k)),
          pass_power_k:power($p; $k),
          wilson:$ci,
          pass_at_k_interval:{lower:(1 - power((1 - $ci.lower); $k)), upper:(1 - power((1 - $ci.upper); $k))},
          pass_power_k_interval:{lower:power($ci.lower; $k), upper:power($ci.upper; $k)},
          sampling_assumption:"IID attempts of the same case/configuration; not empirically verified"
        }
    end'
}

export -f wilson_interval cohen_kappa reliability_metrics

if [[ "$BASH_SOURCE" == "$0" ]]; then
  first="$(printf '%s\n' "$@" | sed -n '1p')"
  case "$first" in
    wilson) shift; wilson_interval "$@" ;;
    kappa)  shift; cohen_kappa "$@" ;;
    reliability) shift; reliability_metrics "$@" ;;
    *) echo "usage: stats.sh {wilson <pass> <n> [z] | kappa <tp> <fp> <tn> <fn> | reliability <pass> <n> <k> [z]}" >&2; exit 2 ;;
  esac
fi
