#!/usr/bin/env bash
# Trusted operator entrypoint: no evaluated repository code runs outside atd-sandbox.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
root="$(cd "$here/../.." && pwd -P)"
if [[ $# -lt 4 || $# -gt 5 ]]; then
  echo 'usage: run.sh ABS_EMPTY_OUTPUT ABS_REPOSITORY COMMIT ABS_DEPS [ABS_BASELINE_APPROVAL]' >&2
  exit 2
fi
out="$1" repo="$2" commit="$3" deps="$4" approval="${5:-}"
: "${ATD_IMG2THREEJS_PRODUCT_ROOT:?set ATD_IMG2THREEJS_PRODUCT_ROOT to the trusted product root}"
for p in "$out" "$repo" "$deps" "$ATD_IMG2THREEJS_PRODUCT_ROOT"; do [[ "$p" = /* ]] || { echo 'paths must be absolute' >&2; exit 2; }; done
[[ -z "$approval" || "$approval" = /* ]] || { echo 'approval must be absolute' >&2; exit 2; }
[[ -d "$out" && -z "$(ls -A "$out")" ]] || { echo 'output must be an existing empty directory' >&2; exit 2; }
mkdir "$out/workdir"
cp "$root/examples/img2threejs-domain/case.yaml" "$out/case.yaml"
cfg="$(node "$here/prepare.mjs" "$out/workdir" "$repo" "$commit" "$deps")"
export EVAL_ATD_POLICY="$here/browser-policy.json"
printf '%s' "$cfg" | node "$root/scripts/eval/discovery/sandbox.mjs" run --workdir="$out/workdir" --transcript="$out/transcript.jsonl"
mkdir "$out/workdir/metrics"
node "$here/bridge.mjs" "$out/workdir/atd-out" "$out/workdir/metrics" "$ATD_IMG2THREEJS_PRODUCT_ROOT" ${approval:+"$approval"}
source "$root/scripts/eval/lib/score.sh"
source "$root/scripts/eval/lib/grading_manifest.sh"
write_case_grading_manifest "$out/case.yaml" "$out/workdir" "$out/transcript.jsonl" "$out/env-manifest.json" img2threejs-domain img2threejs-domain "$out/grading-manifest.json"
bash "$root/scripts/eval/grade.sh" --manifest="$out/grading-manifest.json" --out="$out/case-result.json"
source "$root/scripts/eval/lib/diff.sh"
source "$root/scripts/eval/lib/report_junit.sh"
source "$root/scripts/eval/lib/report_sarif.sh"
cases="$(jq -cs '.' "$out/case-result.json")"
build_run_summary "$cases" img2threejs-domain external > "$out/results.json"
render_diff_md "$out/results.json" "$out/diff.md"
render_junit "$out/results.json" > "$out/junit.xml"
render_sarif "$out/results.json" > "$out/results.sarif"
