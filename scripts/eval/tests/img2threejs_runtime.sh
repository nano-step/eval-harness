#!/usr/bin/env bash
# Runs real confined cases. The baseline must be independently approved before this script runs.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
fixture="$root/examples/img2threejs-domain"
integration="$root/integrations/img2threejs"
if [[ -z "${ATD_IMG2THREEJS_DEPS:-}${ATD_IMG2THREEJS_PRODUCT_ROOT:-}${ATD_IMG2THREEJS_BASELINE_APPROVAL:-}" ]]; then
  echo 'SKIP img2threejs runtime: trusted dependencies, product root and approved baseline are required'
  exit 0
fi
: "${ATD_IMG2THREEJS_DEPS:?trusted dependency snapshot required}"
: "${ATD_IMG2THREEJS_PRODUCT_ROOT:?trusted product root required}"
: "${ATD_IMG2THREEJS_BASELINE_APPROVAL:?independently approved original baseline required}"
export ATD_IMG2THREEJS_PRODUCT_ROOT
baseline_image="$(node -e 'const fs=require("fs"),path=require("path"); const p=path.resolve(process.argv[1]); const a=JSON.parse(fs.readFileSync(p)); console.log(fs.realpathSync(path.resolve(path.dirname(p),a.image)));' "$ATD_IMG2THREEJS_BASELINE_APPROVAL")"
baseline_sha="$(shasum -a 256 "$baseline_image")"
approval_sha="$(shasum -a 256 "$ATD_IMG2THREEJS_BASELINE_APPROVAL")"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
base="$(bash "$fixture/build-fixture-repo.sh" "$tmp/repository")"
run_case() {
  local label="$1" commit="$2" approval="${3:-$ATD_IMG2THREEJS_BASELINE_APPROVAL}"
  mkdir "$tmp/$label"
  bash "$integration/run.sh" "$tmp/$label" "$tmp/repository" "$commit" "$ATD_IMG2THREEJS_DEPS" "$approval" > "$tmp/$label.grade"
}
run_case valid "$base"
for dimension in geometry sceneGraph materials animation runtime; do jq -e '.score == 1' "$tmp/valid/workdir/metrics/$dimension.json" >/dev/null; done
jq -e '.score >= 0.99' "$tmp/valid/workdir/metrics/visual.json" >/dev/null
jq -e '.browser.render.status == "PASS" and .browser.render.calls > 0 and .browser.render.triangles > 0 and .browser.export.status == "PASS"' "$tmp/valid/workdir/atd-out/artifacts/candidate.domain-runtime.json" >/dev/null
[[ -s "$tmp/valid/workdir/atd-out/artifacts/candidate.domain-beauty.png" && -s "$tmp/valid/workdir/atd-out/artifacts/candidate.domain-model.glb" ]]
cp -R "$tmp/valid/workdir/atd-out" "$tmp/tampered"
printf 'x' >> "$tmp/tampered/artifacts/candidate.domain-beauty.png"
mkdir "$tmp/tampered-metrics"
if node "$integration/bridge.mjs" "$tmp/tampered" "$tmp/tampered-metrics" "$ATD_IMG2THREEJS_PRODUCT_ROOT" 2>/dev/null; then
  echo 'tampered signed screenshot was accepted' >&2; exit 1
fi
[[ -z "$(ls -A "$tmp/tampered-metrics")" ]]
mkdir "$tmp/unapproved"
node "$integration/bridge.mjs" "$tmp/valid/workdir/atd-out" "$tmp/unapproved" "$ATD_IMG2THREEJS_PRODUCT_ROOT"
[[ ! -e "$tmp/unapproved/visual.json" ]]
jq -e '.dimensions.visual.status == "UNAVAILABLE"' "$tmp/unapproved/domain-metrics.json" >/dev/null
# Copy only the already-approved original to an external disposable location; alter provenance
# without changing its approval to prove that fixed-configuration drift refuses comparison.
mkdir "$tmp/drift-baseline"
node "$integration/test-variants.mjs" approval-drift "$ATD_IMG2THREEJS_BASELINE_APPROVAL" "$tmp/drift-baseline/approval.json"
mkdir "$tmp/drift"
node "$integration/bridge.mjs" "$tmp/valid/workdir/atd-out" "$tmp/drift" "$ATD_IMG2THREEJS_PRODUCT_ROOT" "$tmp/drift-baseline/approval.json"
[[ ! -e "$tmp/drift/visual.json" ]]
jq -e '.dimensions.visual.status == "UNAVAILABLE"' "$tmp/drift/domain-metrics.json" >/dev/null
for variant in compile load webgl render export visual; do
  git -C "$tmp/repository" -c core.hooksPath=/dev/null checkout -q --detach "$base"
  node "$integration/test-variants.mjs" "$variant" "$fixture/src/scene.ts" "$tmp/repository/src/scene.ts"
  git -C "$tmp/repository" -c core.hooksPath=/dev/null add src/scene.ts
  git -C "$tmp/repository" -c core.hooksPath=/dev/null -c commit.gpgsign=false -c user.name=ATD -c user.email=atd@example.invalid commit -qm "inject $variant defect"
  sha="$(git -C "$tmp/repository" rev-parse HEAD)"
  run_case "$variant" "$sha"
  metrics="$tmp/$variant/workdir/metrics"; runtime="$tmp/$variant/workdir/atd-out/artifacts/candidate.domain-runtime.json"
  case "$variant" in
    compile) jq -e '.compiler.status == "FAIL" and (.compiler.diagnostics | length > 0)' "$runtime" >/dev/null; jq -e '.score == 0' "$metrics/runtime.json" >/dev/null ;;
    load) jq -e '.browser.load.status == "FAIL"' "$runtime" >/dev/null; jq -e '.score == 0' "$metrics/runtime.json" >/dev/null ;;
    webgl|render) jq -e '.browser.render.status == "FAIL"' "$runtime" >/dev/null; jq -e '.score == 0' "$metrics/runtime.json" >/dev/null ;;
    export) jq -e '.browser.export.status == "FAIL"' "$runtime" >/dev/null; jq -e '.score == 0' "$metrics/runtime.json" >/dev/null ;;
    visual) jq -e '.score < 0.99' "$metrics/visual.json" >/dev/null; for dim in geometry sceneGraph materials animation; do jq -e '.score == 1' "$metrics/$dim.json" >/dev/null; done ;;
  esac
done
[[ "$(shasum -a 256 "$baseline_image")" == "$baseline_sha" ]]
[[ "$(shasum -a 256 "$ATD_IMG2THREEJS_BASELINE_APPROVAL")" == "$approval_sha" ]]
echo 'img2threejs runtime acceptance passed'
