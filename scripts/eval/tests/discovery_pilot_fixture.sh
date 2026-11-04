#!/usr/bin/env bash
# Static integrity of the collision pilot fixture: pinned maintained dependencies in the lockfile,
# reproducible isolated revisions, a baseline that intentionally lacks the touching-edge case, and
# well-formed controlled-invocation examples. Nothing is installed, fetched or executed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURE="$SCRIPT_DIR/../../../examples/discovery-pilot/collision"
for tool in jq git; do command -v "$tool" >/dev/null 2>&1 || { echo "SKIP: $tool required" >&2; exit 0; }; done
WORK="$(mktemp -d -t atd-fixture.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

# 1. exact pins, no ranges, and the lockfile agrees
jq -e '[.devDependencies[]] | all(test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))' "$FIXTURE/package.json" >/dev/null || fail "devDependencies must be exact versions"
for pair in "vitest 5.1.0" "fast-check 4.10.2" "@stryker-mutator/core 10.1.1" "@stryker-mutator/vitest-runner 10.1.1"; do
  set -- $pair
  jq -e --arg n "$1" --arg v "$2" '.devDependencies[$n]==$v' "$FIXTURE/package.json" >/dev/null || fail "$1 must be pinned to $2 in package.json"
  jq -e --arg n "node_modules/$1" --arg v "$2" '.packages[$n].version==$v and (.packages[$n].integrity|startswith("sha512-"))' "$FIXTURE/package-lock.json" >/dev/null || fail "$1 $2 missing or unverified in package-lock.json"
done
jq -e '.lockfileVersion==3 and (.packages|length)>50 and ([.packages[]|select(has("resolved"))|.resolved|startswith("https://registry.npmjs.org/")]|all)' "$FIXTURE/package-lock.json" >/dev/null || fail "lockfile must be a v3 registry lockfile"
jq -e --slurpfile p "$FIXTURE/package.json" '.packages[""].devDependencies == $p[0].devDependencies' "$FIXTURE/package-lock.json" >/dev/null || fail "lockfile root and package.json disagree"
[[ ! -e "$FIXTURE/node_modules" ]] || fail "fixture must not contain installed dependencies"

# 2. required contract text and the intentionally missing baseline case
grep -q 'Rectangles that only touch along an edge or at a corner do not overlap\.' "$FIXTURE/SPEC.md" || fail "SPEC.md touching-edge contract"
grep -q 'never overlaps another rectangle' "$FIXTURE/SPEC.md" || fail "SPEC.md zero-size contract"
grep -q 'Negative coordinates are valid' "$FIXTURE/SPEC.md" || fail "SPEC.md negative coordinates"
grep -q 'translation invariant' "$FIXTURE/SPEC.md" || fail "SPEC.md translation invariance"
grep -q 'exactly flush' "$FIXTURE/SPEC.md" || fail "SPEC.md movement boundary"
if grep -qiE 'touch|flush|adjacent|share an edge' <(grep -v '^//' "$FIXTURE/test/collision.test.ts"); then fail "baseline tests must NOT contain a touching-edge or flush-movement case"; fi
grep -q 'seed: 20261103' "$FIXTURE/test/collision.test.ts" || fail "properties must use fixed fast-check seeds"

# 3. reproducible isolated revisions
bash "$FIXTURE/build-fixture-repo.sh" "$WORK/a" > "$WORK/a.json"
bash "$FIXTURE/build-fixture-repo.sh" "$WORK/b" > "$WORK/b.json"
[[ "$(jq -S 'del(.repository)' "$WORK/a.json")" == "$(jq -S 'del(.repository)' "$WORK/b.json")" ]] || fail "revision SHAs must be reproducible"
set +e; bash "$FIXTURE/build-fixture-repo.sh" "$WORK/a" >/dev/null 2>&1; rc=$?; set -e
[[ "$rc" == "2" ]] || fail "a non-empty destination must be refused (rc=$rc)"
BASE="$(jq -r .baseCommit "$WORK/a.json")"; CLEAN="$(jq -r .revisions.clean.commit "$WORK/a.json")"
BOUNDARY="$(jq -r .revisions.boundaryDefect.commit "$WORK/a.json")"; ZERO="$(jq -r .revisions.zeroSizeDefect.commit "$WORK/a.json")"
[[ "$(printf '%s\n' "$BASE" "$CLEAN" "$BOUNDARY" "$ZERO" | sort -u | wc -l | tr -d ' ')" == "4" ]] || fail "four distinct commits expected"
for c in "$CLEAN" "$BOUNDARY" "$ZERO"; do
  [[ "$(git -C "$WORK/a" rev-parse "$c^")" == "$BASE" ]] || fail "$c must be a direct child of the baseline (isolated revision)"
  [[ "$(git -C "$WORK/a" diff --name-only "$BASE" "$c")" == "src/collision.ts" ]] || fail "$c must change only src/collision.ts"
done
[[ -z "$(git -C "$WORK/a" status --porcelain)" ]] || fail "fixture repository must be clean"
[[ "$(git -C "$WORK/a" show "$BOUNDARY:src/collision.ts" | grep -c '<= ')" -ge 2 ]] || fail "boundary defect must relax the x-axis comparisons"
git -C "$WORK/a" show "$CLEAN:src/collision.ts" | grep -q 'intervalsOverlap' || fail "clean change must be the helper refactor"
git -C "$WORK/a" show "$BASE:test/collision.test.ts" >/dev/null || fail "baseline tests must be in the baseline commit"
[[ "$(git -C "$WORK/a" ls-tree -r --name-only "$BASE" | grep -c 'patches/\|build-fixture')" == "0" ]] || fail "patches and tooling must not be part of the code under test"

# 4. controlled invocation examples are well-formed and use only known placeholders
for f in "$FIXTURE"/config/*.json; do jq -e . "$f" >/dev/null || fail "$f is not valid JSON"; done
KNOWN='EVAL_HARNESS_ROOT|WORK|NODE|FIXTURE_REPO|DEPENDENCIES|BASE_COMMIT|DEFECT_COMMIT'
if grep -ho '@@[A-Z_]*@@' "$FIXTURE"/config/* | tr -d '@' | grep -vxE "$KNOWN" | grep -q .; then fail "unknown placeholder in config examples"; fi
jq -e '.schema=="atd.qa-hook-config/v1" and (.profiles|length)==1' "$FIXTURE/config/qa-hook-config.example.json" >/dev/null || fail "QA adapter config example"
jq -e '.purpose=="oracle" and (.command[0]|endswith("integrations/qa-factory/discovery.py"))' "$FIXTURE/config/qa-oracle-hook.example.json" >/dev/null || fail "QA hook registration example"
jq -e '.oracle_id=="collision-boundary" and (.operation_id|length)>0 and (.namespace|length)>0' "$FIXTURE/config/qa-hook-request.example.json" >/dev/null || fail "QA request example"
jq -e '.maxRepairRounds==3 and (.testCommand|contains("--mode=warn"))' "$FIXTURE/config/jev-gate.example.json" >/dev/null || fail "Jev gate example"
grep -q '^runner: atd-sandbox' "$FIXTURE/config/skill-case.example.yaml" || fail "skill case example runner"
grep -q 'kind: discovery_finding' "$FIXTURE/config/skill-case.example.yaml" || fail "skill case example check"

echo "PASS discovery_pilot_fixture"
