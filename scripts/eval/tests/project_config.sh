#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d -t eval-harness-cfg.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/proj/.opencode/skills/foo/evals/cases"
cat > "$WORK/proj/.opencode/eval-harness.yaml" <<YAML
model: anthropic/claude-from-project
budget_usd: 5.00
max_seconds: 99
llm_judge:
  model: anthropic/claude-opus-4-7
YAML

cd "$WORK/proj"

unset EVAL_MODEL EVAL_BUDGET_USD EVAL_MAX_SECONDS EVAL_LLM_JUDGE_MODEL OPENCODE_SKILLS_ROOT EVAL_HARNESS_CONFIG

# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/yq-shim.sh"
source "$SCRIPT_DIR/../lib/skills_root.sh"
source "$SCRIPT_DIR/../lib/config.sh"

CFG_PATH="$(resolve_project_config)"
if [[ "$CFG_PATH" != "$WORK/proj/.opencode/eval-harness.yaml" ]]; then
  echo "FAIL: resolve_project_config returned '$CFG_PATH'" >&2
  exit 1
fi

apply_project_config

[[ "$EVAL_MODEL" == "anthropic/claude-from-project" ]] || { echo "FAIL: EVAL_MODEL='$EVAL_MODEL'" >&2; exit 1; }
[[ "$EVAL_BUDGET_USD" == "5.0" || "$EVAL_BUDGET_USD" == "5.00" ]] || { echo "FAIL: EVAL_BUDGET_USD='$EVAL_BUDGET_USD'" >&2; exit 1; }
[[ "$EVAL_MAX_SECONDS" == "99" ]] || { echo "FAIL: EVAL_MAX_SECONDS='$EVAL_MAX_SECONDS'" >&2; exit 1; }
[[ "$EVAL_LLM_JUDGE_MODEL" == "anthropic/claude-opus-4-7" ]] || { echo "FAIL: EVAL_LLM_JUDGE_MODEL='$EVAL_LLM_JUDGE_MODEL'" >&2; exit 1; }

export EVAL_MODEL="explicit-env-wins"
unset EVAL_BUDGET_USD EVAL_MAX_SECONDS EVAL_LLM_JUDGE_MODEL
apply_project_config
[[ "$EVAL_MODEL" == "explicit-env-wins" ]] || { echo "FAIL: env-var precedence broken; got '$EVAL_MODEL'" >&2; exit 1; }
[[ "$EVAL_BUDGET_USD" == "5.0" || "$EVAL_BUDGET_USD" == "5.00" ]] || { echo "FAIL: BUDGET should fill from config when unset, got '$EVAL_BUDGET_USD'" >&2; exit 1; }


pre_push_should_fire "feature/topic" || { echo "FAIL: branches should fire when no filters are configured" >&2; exit 1; }
cat > "$WORK/proj/.opencode/eval-harness.yaml" <<YAML
pre_push:
  branches:
    include: ["release/*"]
    exclude: ["release/skip"]
YAML
pre_push_should_fire "release/v0.5.0" || { echo "FAIL: included branch was skipped" >&2; exit 1; }
pre_push_should_fire "release/skip" || { echo "FAIL: include should take precedence over exclude" >&2; exit 1; }
if pre_push_should_fire "feature/topic"; then
  echo "FAIL: branch outside include was allowed" >&2
  exit 1
fi
cat > "$WORK/proj/.opencode/eval-harness.yaml" <<YAML
pre_push:
  branches:
    exclude: ["wip/*"]
YAML
if pre_push_should_fire "wip/experiment"; then
  echo "FAIL: excluded branch was allowed" >&2
  exit 1
fi
pre_push_should_fire "main" || { echo "FAIL: unrelated branch was excluded" >&2; exit 1; }

echo "PASS: project-config resolution, precedence, and pre-push branch policy"
echo "PASS: project-config layer resolved + applied with correct precedence"
exit 0
