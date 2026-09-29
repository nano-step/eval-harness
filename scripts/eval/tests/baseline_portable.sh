#!/usr/bin/env bash
# Regression test for EV-P0a / C1: a portable baseline ignores ONLY model_id+opencode_version
# (no false MODEL_CHANGED across machines) but STILL surfaces a real skill_sha regression as
# SKILL_CHANGED — it must never short-circuit deltas into UNKNOWN_DRIFT.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/manifest.sh"
source "$SCRIPT_DIR/../lib/attribute.sh"

WORK="$(mktemp -d -t eval-harness-portbase.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

# Baseline manifest, marked portable.
cat > "$WORK/base.json" <<'JSON'
{"model_id":"anthropic/claude-3-5-haiku-latest","opencode_version":"1.15.10","skill_sha":"S1","fixture_sha":"F1","skill_bundle_sha":"B1","portable":true}
JSON

attr_top() { # attr_top <current.json> <baseline.json>
  attribute "$(diff_manifests "$2" "$1")" | jq -r '.top'
}

# 1. Env drift only (model_id + opencode_version changed, skill unchanged) on a PORTABLE
#    baseline -> NOT MODEL_CHANGED.
cat > "$WORK/cur_env.json" <<'JSON'
{"model_id":"anthropic/claude-sonnet-4-6","opencode_version":"1.99.0","skill_sha":"S1","fixture_sha":"F1","skill_bundle_sha":"B1"}
JSON
top="$(attr_top "$WORK/cur_env.json" "$WORK/base.json")"
[[ "$top" != "MODEL_CHANGED" ]] || { echo "FAIL: portable baseline false-flagged MODEL_CHANGED on env-only drift (top=$top)" >&2; exit 1; }

# 2. THE C1 GUARD: model_id changed AND skill_sha changed on a PORTABLE baseline -> the skill
#    regression must still surface as SKILL_CHANGED (NOT laundered to UNKNOWN_DRIFT/MODEL_CHANGED).
cat > "$WORK/cur_skill.json" <<'JSON'
{"model_id":"anthropic/claude-sonnet-4-6","opencode_version":"1.99.0","skill_sha":"S2","fixture_sha":"F1","skill_bundle_sha":"B2"}
JSON
top="$(attr_top "$WORK/cur_skill.json" "$WORK/base.json")"
[[ "$top" == "SKILL_CHANGED" ]] || { echo "FAIL: C1 — portable baseline masked a real skill_sha regression as '$top' (expected SKILL_CHANGED)" >&2; diff_manifests "$WORK/base.json" "$WORK/cur_skill.json" >&2; exit 1; }

# 3. Portable baseline still catches a fixture regression.
cat > "$WORK/cur_fix.json" <<'JSON'
{"model_id":"anthropic/claude-3-5-haiku-latest","opencode_version":"1.15.10","skill_sha":"S1","fixture_sha":"F2","skill_bundle_sha":"B1"}
JSON
top="$(attr_top "$WORK/cur_fix.json" "$WORK/base.json")"
[[ "$top" == "FIXTURE_STALE" ]] || { echo "FAIL: portable baseline missed a fixture_sha change (top=$top)" >&2; exit 1; }

# 4. A PINNED baseline (no portable marker) preserves existing behavior: model_id change -> MODEL_CHANGED.
cat > "$WORK/base_pinned.json" <<'JSON'
{"model_id":"anthropic/claude-3-5-haiku-latest","opencode_version":"1.15.10","skill_sha":"S1","fixture_sha":"F1","skill_bundle_sha":"B1"}
JSON
top="$(attr_top "$WORK/cur_env.json" "$WORK/base_pinned.json")"
[[ "$top" == "MODEL_CHANGED" ]] || { echo "FAIL: pinned baseline should still attribute MODEL_CHANGED (top=$top)" >&2; exit 1; }

echo "PASS: portable baseline ignores model/opencode env drift but still catches SKILL_CHANGED/FIXTURE_STALE; pinned baseline unchanged"
exit 0
