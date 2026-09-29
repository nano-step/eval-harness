#!/usr/bin/env bash
# scripts/eval/apply.sh — apply auto-fix proposals from a completed run (#14).
#
# v0.4.x only *proposed* fixes (auto_apply:false). This applies the mechanically-safe
# ones with explicit confirmation. Safety contract:
#   - Only proposals with auto_apply:true are ever applied (today: missing_file).
#   - confidence:high by default; medium requires --medium.
#   - Refuses if --target-dir is inside a git repo with uncommitted changes.
#   - Prints each change and requires y/N before writing (skip with --yes / --all).
#
# Open design question (see issue #14): 3-way merge vs 1-way patch. This MVP does a
# 1-way create for missing_file; other proposal kinds remain proposal-only.

set -euo pipefail

usage() {
  cat <<EOF
Usage: eval-harness apply --run=<run_id> [options]

Options:
  --run=<run_id>     Run to apply proposals from (required)
  --all              Apply every eligible proposal non-interactively (implies --yes)
  --yes              Don't prompt; apply eligible proposals (test/CI mode)
  --medium           Also apply confidence:medium proposals (default: high only)
  --kind=<kind>      Only apply proposals of this kind (e.g. missing_file)
  --target-dir=<d>   Directory to apply changes into (default: cwd)
  -h, --help         Show this help

Only proposals marked auto_apply:true are ever applied.
EOF
}

RUN_ID=""; ALL=0; YES=0; MEDIUM=0; KIND=""; TARGET_DIR="$(pwd)"
for arg in "$@"; do
  case "$arg" in
    --run=*)        RUN_ID="${arg#*=}" ;;
    --all)          ALL=1; YES=1 ;;
    --yes)          YES=1 ;;
    --medium)       MEDIUM=1 ;;
    --kind=*)       KIND="${arg#*=}" ;;
    --target-dir=*) TARGET_DIR="${arg#*=}" ;;
    -h|--help)      usage; exit 0 ;;
    apply)          ;;
    *) echo "unknown arg: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -z "$RUN_ID" ]]; then
  echo "error: --run=<run_id> is required" >&2; usage >&2; exit 2
fi

STATE_DIR="${EVAL_STATE_DIR:-$HOME/.config/opencode/eval-harness}"
RESULTS="$STATE_DIR/runs/$RUN_ID/results.json"
if [[ ! -f "$RESULTS" ]]; then
  echo "[eval-harness] apply: no results.json for run '$RUN_ID' ($RESULTS)" >&2
  exit 2
fi

mkdir -p "$TARGET_DIR"

# Refuse to mutate a dirty git working tree (no clobbering uncommitted work).
if git -C "$TARGET_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if [[ -n "$(git -C "$TARGET_DIR" status --porcelain 2>/dev/null)" ]]; then
    echo "[eval-harness] apply: $TARGET_DIR is a git repo with uncommitted changes. Commit/stash first." >&2
    exit 3
  fi
fi

# Select eligible proposals: auto_apply true, confidence allowed, kind filter.
allowed_conf='["high"]'
[[ "$MEDIUM" == "1" ]] && allowed_conf='["high","medium"]'

proposals=()
while IFS= read -r _proposal; do
  [[ -n "$_proposal" ]] && proposals+=("$_proposal")
done < <(jq -c \
  --argjson conf "$allowed_conf" \
  --arg kind "$KIND" \
  '.cases[].checks[]?
   | select(.fix_proposal != null)
   | .fix_proposal
   | select(.auto_apply == true)
   | select(.confidence as $c | $conf | index($c))
   | select($kind == "" or .kind == $kind)' "$RESULTS")

if [[ ${#proposals[@]} -eq 0 ]]; then
  echo "[eval-harness] apply: no eligible auto-applicable proposals in run $RUN_ID"
  exit 0
fi

applied=0
skipped=0
for p in "${proposals[@]}"; do
  kind="$(echo "$p" | jq -r '.kind')"
  instruction="$(echo "$p" | jq -r '.instruction')"
  snippet="$(echo "$p" | jq -r '.patch_snippet')"

  echo "----------------------------------------------------------------"
  echo "proposal: $kind (confidence: $(echo "$p" | jq -r '.confidence'))"
  echo "  $instruction"

  case "$kind" in
    missing_file)
      # Path-traversal guard: snippet comes from author-controlled case YAML. Reject
      # absolute paths / '..' and verify the resolved dest stays under TARGET_DIR before
      # we ever write (mirrors run.sh fixture-materialization safety).
      if [[ "$snippet" = /* || "$snippet" == *..* ]]; then
        echo "  ! refusing unsafe path '$snippet' (absolute or contains '..') — skipping" >&2
        skipped=$((skipped+1)); continue
      fi
      dest="$TARGET_DIR/$snippet"
      _canon_dest="$(python3 -c "import os,sys;print(os.path.realpath(sys.argv[1]))" "$dest")"
      _canon_tgt="$(python3 -c "import os,sys;print(os.path.realpath(sys.argv[1]))" "$TARGET_DIR")"
      if [[ "$_canon_dest" != "$_canon_tgt"/* ]]; then
        echo "  ! refusing path '$snippet' — resolves outside target dir — skipping" >&2
        skipped=$((skipped+1)); continue
      fi
      echo "  + create file: $dest"
      ;;
    *)
      echo "  (kind '$kind' is proposal-only; not auto-applicable — skipping)"
      skipped=$((skipped+1))
      continue
      ;;
  esac

  if [[ "$YES" != "1" ]]; then
    printf "apply this change? [y/N] " >&2
    read -r answer
    case "$answer" in y|Y|yes|YES) ;; *) echo "  skipped"; skipped=$((skipped+1)); continue ;; esac
  fi

  case "$kind" in
    missing_file)
      # Refuse to clobber an existing file.
      if [[ -e "$dest" ]]; then
        echo "  ! $dest already exists — skipping" >&2
        skipped=$((skipped+1))
        continue
      fi
      mkdir -p "$(dirname "$dest")"
      : > "$dest"
      echo "  created $dest"
      applied=$((applied+1))
      ;;
  esac
done

echo "----------------------------------------------------------------"
echo "[eval-harness] apply: $applied applied, $skipped skipped (run $RUN_ID)"
exit 0
