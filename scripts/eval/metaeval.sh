#!/usr/bin/env bash
# scripts/eval/metaeval.sh — "eval of the eval" (#EV-1). Drives the harness over a corpus of
# KNOWN regressions and benign edits (stub opencode, fully offline) and measures the harness's
# OWN false-positive rate, false-negative rate, and attribution accuracy. This is a level-2
# harness-validity metric (NOT a skill verdict) and writes its own metaeval.json.
#
# Recursion/cost guard: metaeval must run stub-only. If a real `opencode` is on PATH it ABORTS
# (would spawn paid sessions) unless EVAL_METAEVAL_ALLOW_REAL=1.

set -uo pipefail

_resolve_script_dir() {
  local src="${BASH_SOURCE[0]}"
  while [[ -L "$src" ]]; do local d; d="$(cd "$(dirname "$src")" && pwd)"; src="$(readlink "$src")"; [[ "$src" != /* ]] && src="$d/$src"; done
  cd "$(dirname "$src")" && pwd
}
SCRIPT_DIR="$(_resolve_script_dir)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RUN="$SCRIPT_DIR/run.sh"
BASELINE="$SCRIPT_DIR/baseline.sh"
source "$SCRIPT_DIR/lib/yq-shim.sh"

_metaeval_tree_sha() {
  bash -c 'source "$1"; portable_tree_sha256 "$2"' _ "$SCRIPT_DIR/lib/portable.sh" "$1"
}

CORPUS="$REPO_ROOT/skills/eval-harness/meta"
OUT=""
for arg in "$@"; do
  case "$arg" in
    --corpus=*) CORPUS="${arg#*=}" ;;
    --out=*)    OUT="${arg#*=}" ;;
    -h|--help)  echo "Usage: eval-harness metaeval [--corpus=DIR] [--out=metaeval.json]"; exit 0 ;;
    metaeval)   ;;
    *) echo "unknown arg: $arg" >&2; exit 2 ;;
  esac
done

# --- Recursion / token-bomb guard (SD-5) ---
if command -v opencode >/dev/null 2>&1 && [[ "${EVAL_METAEVAL_ALLOW_REAL:-0}" != "1" ]]; then
  echo "[eval-harness] metaeval: a real 'opencode' is on PATH — metaeval must run stub-only to stay offline/free." >&2
  echo "  Remove opencode from PATH for this run, or set EVAL_METAEVAL_ALLOW_REAL=1 (NOT recommended)." >&2
  exit 2
fi

[[ -d "$CORPUS" ]] || { echo "[eval-harness] metaeval: corpus dir not found: $CORPUS" >&2; exit 2; }

# Run one corpus scenario in full isolation; echoes "<verdict> <attribution_top>".
_metaeval_scenario() {
  local mutation="$1" tree_before tree_after mutation_applied
  local W; W="$(mktemp -d -t eval-metaeval.XXXXXX)"
  local skroot="$W/skills" state="$W/state" stub="$W/bin"
  mkdir -p "$skroot/sut/evals/cases" "$state" "$stub"
  echo "sut skill v1" > "$skroot/sut/SKILL.md"
  cat > "$skroot/sut/evals/cases/c1.yaml" <<YAML
schema_version: 2
id: c1
prompt: noop
checks:
  - kind: file_exists
    path: out.txt
YAML
  # Second skill present for the cross-skill scenario (in the bundle at baseline time).
  if [[ "$mutation" == "cross_skill" ]]; then
    mkdir -p "$skroot/other"; echo "other skill v1" > "$skroot/other/SKILL.md"
  fi
  # Stub opencode: creates out.txt unless a FAILMODE marker exists (lets us flip behavior).
  cat > "$stub/opencode" <<STUB
#!/usr/bin/env bash
[[ "\${1:-}" == "--version" ]] && { echo "1.15.10-stub"; exit 0; }
cwd="\$(pwd)"
while [[ \$# -gt 0 ]]; do case "\$1" in --dir) cwd="\$2"; shift 2;; --dir=*) cwd="\${1#*=}"; shift;; *) shift;; esac; done
[[ -f "$W/FAILMODE" ]] || : > "\$cwd/out.txt"
echo "{}"
exit 0
STUB
  chmod +x "$stub/opencode"

  local env_common=(env "PATH=$stub:$PATH" "EVAL_STATE_DIR=$state" "OPENCODE_SKILLS_ROOT=$skroot" "EVAL_SKIP_AUTH_CHECK=1")

  # Baseline (PASS).
  "${env_common[@]}" bash "$BASELINE" --skill=sut --case=c1 --force >/dev/null 2>&1 || true
  tree_before="$(_metaeval_tree_sha "$skroot")"

  # Apply the mutation.
  case "$mutation" in
    skill_regression)  echo "regressed $(date -u +%s 2>/dev/null || echo x)" >> "$skroot/sut/SKILL.md"; : > "$W/FAILMODE" ;;
    cross_skill)       echo "other changed" >> "$skroot/other/SKILL.md"; : > "$W/FAILMODE" ;;   # SUT unchanged
    benign_skill_edit) echo "# harmless comment" >> "$skroot/sut/SKILL.md" ;;                    # no FAILMODE -> still PASS
    benign_whitespace) printf '   ' >> "$skroot/sut/SKILL.md" ;;                         # whitespace-only skill edit; no FAILMODE
  esac
  tree_after="$(_metaeval_tree_sha "$skroot")"
  mutation_applied=false
  [[ "$tree_before" == "$tree_after" ]] || mutation_applied=true
  if [[ "$mutation_applied" != "true" ]]; then
    echo "ERR null false"
    rm -rf "$W"
    return 1
  fi

  # Re-run and read the harness's verdict + attribution.
  "${env_common[@]}" bash "$RUN" --skill=sut --case=c1 --trigger=manual >/dev/null 2>&1 || true
  local rj; rj="$(ls -dt "$state/runs"/* 2>/dev/null | head -1)/results.json"
  local verdict="ERR" attr="null"
  if [[ -f "$rj" ]]; then
    verdict="$(jq -r '.verdict' "$rj" 2>/dev/null || echo ERR)"
    attr="$(jq -r '.cases[0].attribution.top // "null"' "$rj" 2>/dev/null || echo null)"
  fi
  rm -rf "$W"
  echo "$verdict $attr $mutation_applied"
}

fp=0; fn=0; attr_ok=0; attr_total=0; n_regress=0; n_benign=0; entries_json="[]"

for entry in "$CORPUS"/*/; do
  [[ -f "$entry/expected.json" ]] || continue
  name="$(basename "$entry")"
  mutation="$(jq -r '.mutation' "$entry/expected.json")"
  exp_verdict="$(jq -r '.expected_verdict' "$entry/expected.json")"
  exp_attr="$(jq -r '.expected_attribution_top // "null"' "$entry/expected.json")"
  should_detect="$(jq -r '.should_detect' "$entry/expected.json")"

  read -r got_verdict got_attr mutation_applied < <(_metaeval_scenario "$mutation")
  if [[ "$mutation_applied" != "true" ]]; then
    echo "[metaeval] scenario '$name' did not mutate its input" >&2
    exit 13
  fi
  detected="false"; [[ "$got_verdict" == "REGRESSION" ]] && detected="true"

  if [[ "$should_detect" == "true" ]]; then
    n_regress=$((n_regress+1))
    [[ "$detected" != "true" ]] && fn=$((fn+1))                       # false negative: missed a real regression
    attr_total=$((attr_total+1))
    [[ "$got_attr" == "$exp_attr" ]] && attr_ok=$((attr_ok+1))        # attribution accuracy (on detected regressions)
  else
    n_benign=$((n_benign+1))
    [[ "$detected" == "true" ]] && fp=$((fp+1))                       # false positive: flagged a benign edit
  fi

  entries_json="$(echo "$entries_json" | jq \
    --arg n "$name" --arg m "$mutation" --arg ev "$exp_verdict" --arg gv "$got_verdict" \
    --arg ea "$exp_attr" --arg ga "$got_attr" --argjson sd "$([[ "$should_detect" == "true" ]] && echo true || echo false)" --argjson ma "$mutation_applied" \
    '. + [{name:$n, mutation:$m, expected_verdict:$ev, got_verdict:$gv, expected_attribution:$ea, got_attribution:$ga, should_detect:$sd, mutation_applied:$ma}]')"
  echo "[metaeval] $name: mutation=$mutation got=$got_verdict/$got_attr (expected $exp_verdict/$exp_attr)" >&2
done
if [[ "$(printf '%s' "$entries_json" | jq 'length')" -eq 0 ]]; then
  echo "[eval-harness] metaeval: corpus has no expected.json scenarios: $CORPUS" >&2
  exit 2
fi

metaeval_json="$(jq -n \
  --argjson fp "$fp" --argjson fn "$fn" --argjson nr "$n_regress" --argjson nb "$n_benign" \
  --argjson ao "$attr_ok" --argjson at "$attr_total" --argjson entries "$entries_json" \
  --arg ts "$(date -u +%FT%TZ)" \
  '{
     schema_version: 1, kind: "metaeval", computed_at: $ts,
     summary: {
       regressions: $nr, benign: $nb,
       false_negatives: $fn, false_positives: $fp,
       false_negative_rate: (if $nr>0 then ($fn/$nr) else null end),
       false_positive_rate: (if $nb>0 then ($fp/$nb) else null end),
       attribution_correct: $ao, attribution_total: $at,
       attribution_accuracy: (if $at>0 then ($ao/$at) else null end)
     },
     entries: $entries
   }')"

if [[ -n "$OUT" ]]; then mkdir -p "$(dirname "$OUT")" 2>/dev/null || true; echo "$metaeval_json" > "$OUT"; fi
echo "$metaeval_json"
echo "[eval-harness] metaeval: FN=$fn/$n_regress FP=$fp/$n_benign attribution=$attr_ok/$attr_total" >&2
exit 0
