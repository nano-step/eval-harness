#!/usr/bin/env bash
# tests/atd/fixture.sh — shared helpers for the atd_* suites (sourced, never run by test.sh:
# test.sh only globs tests/*.sh). Builds a real git repository with a tiny module in several
# revisions and materialises generated-test workdirs exactly as the discovery workflow does.

ATD_FX_TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ATD_FX_EVAL_DIR="$(cd "$ATD_FX_TESTS_DIR/.." && pwd)"
ATD_FX_RUNNER="$ATD_FX_EVAL_DIR/runners/atd-sandbox.sh"
ATD_FX_POLICY="$ATD_FX_EVAL_DIR/discovery/policy/atd-sandbox.v1.json"
ATD_FX_PINNED_IMAGE="$(jq -r '.image.ref' "$ATD_FX_POLICY")"
ATD_FX_ZERO64="$(printf '%064d' 0)"

atd_fx_pass() { echo "  ok  - $1"; }
atd_fx_fail() { echo "  FAIL - $1" >&2; ATD_FX_FAILED=1; }
ATD_FX_FAILED=0
atd_fx_expect() { # <description> <command...>
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then atd_fx_pass "$desc"; else atd_fx_fail "$desc"; fi
}
atd_fx_finish() { if [[ "$ATD_FX_FAILED" == "0" ]]; then echo "PASS"; exit 0; fi; echo "FAILED" >&2; exit 1; }

# Live Docker path available? (daemon + pinned image). Suites needing it SKIP otherwise.
atd_fx_sandbox_available() {
  command -v docker >/dev/null 2>&1 || return 1
  docker version --format '{{.Server.Version}}' >/dev/null 2>&1 || return 1
  docker image inspect "$ATD_FX_PINNED_IMAGE" >/dev/null 2>&1 || return 1
}
atd_fx_skip_unless_sandbox() {
  if ! atd_fx_sandbox_available; then
    echo "SKIP: Docker daemon or pinned image $ATD_FX_PINNED_IMAGE unavailable (live sandbox assertions need both)"
    exit 0
  fi
}

atd_fx_git() { git -C "$ATD_FX_REPO" -c user.name=atd -c user.email=atd@example.invalid -c commit.gpgsign=false "$@"; }

atd_fx_commit() { # <message> -> prints sha
  atd_fx_git add -A >/dev/null
  atd_fx_git commit -q -m "$1" --allow-empty
  atd_fx_git rev-parse HEAD
}

# atd_fx_new_repo <dir>: sets ATD_FX_REPO and SHA_* revisions.
atd_fx_new_repo() {
  ATD_FX_REPO="$1"
  mkdir -p "$ATD_FX_REPO/src"
  git -C "$ATD_FX_REPO" init -q
  printf '{"type":"module","name":"atd-fixture","private":true}\n' > "$ATD_FX_REPO/package.json"
  cat > "$ATD_FX_REPO/src/clamp.mjs" <<'EOF'
export function clamp(value, lo, hi) {
  if (value < lo) return lo;
  if (value > hi) return hi;
  return value;
}
EOF
  SHA_GOOD="$(atd_fx_commit good)"
  cat > "$ATD_FX_REPO/src/clamp.mjs" <<'EOF'
// cosmetic change only: behaviour identical
export function clamp(value, lo, hi) {
  if (value < lo) return lo;
  if (value > hi) return hi;
  return value;
}
EOF
  SHA_COSMETIC="$(atd_fx_commit cosmetic)"
  cat > "$ATD_FX_REPO/src/clamp.mjs" <<'EOF'
export function clamp(value, lo, hi) {
  if (value < lo) return lo;
  if (value >= hi) return hi - 1;
  return value;
}
EOF
  SHA_REGRESS="$(atd_fx_commit regress-upper-boundary)"
  cat > "$ATD_FX_REPO/src/clamp.mjs" <<'EOF'
export function clamp(value, lo, hi) {
  if (value <= lo) return lo + 1;
  if (value > hi) return hi - 1;
  return value;
}
EOF
  SHA_REGRESS2="$(atd_fx_commit regress-both)"
  cat > "$ATD_FX_REPO/src/clamp.mjs" <<'EOF'
export function clamp(value, lo, hi) {
  if (value < lo) return lo;
  if (value > hi) return hi;
  return value;
}
EOF
  printf '{"lockfileVersion":3,"packages":{"":{"name":"a"}}}\n' > "$ATD_FX_REPO/package-lock.json"
  SHA_LOCK_A="$(atd_fx_commit lock-a)"
  printf '{"lockfileVersion":3,"packages":{"":{"name":"b"}}}\n' > "$ATD_FX_REPO/package-lock.json"
  SHA_LOCK_B="$(atd_fx_commit lock-b)"
  # A revision derived from GOOD that adds a module the base does not have.
  atd_fx_git checkout -q --detach "$SHA_GOOD"
  printf 'export const answer = 42;\n' > "$ATD_FX_REPO/src/new.mjs"
  SHA_NEWMOD="$(atd_fx_commit new-module)"
}

ATD_FX_TEST_UPPER_BOUNDARY='import test from "node:test";
import assert from "node:assert/strict";
import { clamp } from "../src/clamp.mjs";
test("upper boundary is inclusive", () => { assert.equal(clamp(10, 0, 10), 10); });
test("inside range is unchanged", () => { assert.equal(clamp(5, 0, 10), 5); });
'

# atd_fx_case <workdir> <candidate-id> <test-body> [framework] [test-file]
# Writes tests/<file>, candidate.json (with the correct testSha256) and SPEC.md exactly like the generator.
atd_fx_case() {
  local workdir="$1" id="$2" body="$3" framework="${4:-node:test}" file="${5:-clamp.test.mjs}" sha
  mkdir -p "$workdir/tests/$(dirname "$file")"
  printf '%s' "$body" > "$workdir/tests/$file"
  sha="$(shasum -a 256 "$workdir/tests/$file" | cut -d' ' -f1)"
  jq -n --arg id "$id" --arg sha "$sha" --arg fw "$framework" --arg file "$file" --arg z "$ATD_FX_ZERO64" \
    --arg base "${ATD_FX_BASE:-$SHA_GOOD}" --arg cand "${ATD_FX_CANDIDATE:-$SHA_GOOD}" '{
      schema:"atd.test-candidate/v1", id:$id, strategy:"intent_aware", targetFile:"src/clamp.mjs", testFile:$file,
      framework:$fw, testSha256:$sha, requirementRef:null, failureHypothesis:"upper boundary is inclusive",
      provenance:{baseCommit:$base,candidateCommit:$cand,sourceDiffHash:$z,generatorRole:"test",promptSha256:$z}, trust:"untrusted"}' > "$workdir/candidate.json"
  printf 'clamp(value, lo, hi) returns hi when value equals hi.\n' > "$workdir/SPEC.md"
}

# atd_fx_config <base-sha> <candidate-sha> [extra-jq-object]
atd_fx_config() {
  local extra="${3:-}"; [[ -n "$extra" ]] || extra='{}'
  # Flat fixtures import ../src from tests/<file>: input root tests (default) AND revision placement tests.
  jq -nc --arg repo "$ATD_FX_REPO" --arg base "$1" --arg cand "$2" --argjson extra "$extra" \
    '{repository:$repo,baseCommit:$base,candidateCommit:$cand,testsRel:"tests",seed:7,timeoutSeconds:60} + $extra'
}

# atd_fx_spawn <workdir> <config-json>: runs the real adapter; sets ATD_FX_RC, ATD_FX_TRANSCRIPT, ATD_FX_ERR.
atd_fx_spawn() {
  local workdir="$1" cfg="$2"
  ATD_FX_TRANSCRIPT="$workdir/../transcript.jsonl"
  ATD_FX_ERR="$workdir/../spawn.err"
  ATD_FX_RC=0
  EVAL_RUN_ID="${EVAL_RUN_ID:-run-test}" EVAL_CASE_ID="${EVAL_CASE_ID:-case-test}" \
    bash "$ATD_FX_RUNNER" spawn "$workdir" "$cfg" "$ATD_FX_TRANSCRIPT" "unused prompt" >"$workdir/../spawn.out" 2>"$ATD_FX_ERR" || ATD_FX_RC=$?
}

atd_fx_verify_json() { # <out-dir> -> sets ATD_FX_VRC and ATD_FX_VJSON
  ATD_FX_VRC=0
  ATD_FX_VJSON="$(bash "$ATD_FX_EVAL_DIR/lib/atd_attest.sh" verify "$1")" || ATD_FX_VRC=$?
}

# --- concurrency-safe container accounting -------------------------------------------------------
# Other atd runs (pilot, parallel suites) legitimately own containers carrying the same atd.owner
# label, so cleanup is asserted only for THIS case's identities: the per-workdir/out-dir label the
# controller already sets (atd.workdir = sha256(path)[:16]) and the container names derived from the
# executionIds in this case's signed records (atd-<side>-<executionId[5:21]>; mutation: atd-mut-...).
atd_fx_path_tag() { printf '%s' "$1" | shasum -a 256 | cut -c1-16; }

# atd_fx_own_containers <path-given-to-the-controller> <record.json...> -> prints "<count> <names>" of this case's containers still present
atd_fx_own_containers() {
  local tag rec id side prefix name found="" count=0 ids
  tag="$(atd_fx_path_tag "$1")"; shift
  ids="$(docker ps -a --filter label=atd.owner=eval-harness --filter "label=atd.workdir=$tag" --format '{{.Names}}')"
  while IFS= read -r name; do [[ -n "$name" ]] && { found="$found $name"; count=$((count+1)); }; done <<<"$ids"
  for rec in "$@"; do
    [[ -f "$rec" ]] || continue
    id="$(jq -r .executionId "$rec")"; side="$(jq -r .side "$rec")"
    prefix="atd-$side"; [[ "$side" == "mutant" ]] && prefix="atd-mut"
    name="$prefix-${id:5:16}"
    if [[ -n "$(docker ps -aq --filter "name=^${name}\$")" ]]; then found="$found $name"; count=$((count+1)); fi
  done
  printf '%s%s\n' "$count" "$found"
}
