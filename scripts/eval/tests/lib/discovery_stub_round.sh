#!/usr/bin/env bash
# Shared helpers for the discovery gate / QA hook tests (test-only; never used by product code).
#
#  * install_stub_run_mjs <dir>   a stub run.mjs that replays a canned round directory (no model, no Docker)
#  * make_scenario <dir> <kind>   builds that round directory from REAL signed atd evidence: the real attest.mjs signer,
#                                 the real score.sh / grading_manifest.sh / diff.sh path and 3 fresh stability samples
#                                 (tests/lib/atd-fixture.sh), so grade.sh can genuinely replay it. Independent-trust
#                                 scenarios are signed with an external key pair (trust label separate-user).
#  * forge_* / tamper_* / drop_*  consumer-visible attacks on the preserved round (edited JSON, edited artifact,
#                                 deleted signature) that the independent recomputation must catch.
#
# Requires: source lib/atd-fixture.sh and fx_init first (sets FX_TMP and EVAL_STATE_DIR); ssh-keygen; jq; node.

# install_stub_run_mjs <dir>: writes a stub run.mjs into <dir>.
install_stub_run_mjs() {
cat > "$1/run.mjs" <<'JS'
// Test stub for run.mjs: copies the canned scenario named by STUB_SCENARIO into a new round directory.
import fs from "node:fs";
import path from "node:path";
const arg = name => process.argv.find(a => a.startsWith(`--${name}=`))?.slice(name.length + 3);
const out = arg("out");
const candidate = arg("candidate");
// The scenario comes from STUB_SCENARIO, or from a scenario.path file beside the stub (QA hook tests: the
// adapter scrubs the environment before launching the pipeline).
const here = path.dirname(new URL(import.meta.url).pathname);
const scenarioFile = path.join(here, "scenario.path");
if (!process.env.STUB_SCENARIO && fs.existsSync(scenarioFile)) process.env.STUB_SCENARIO = fs.readFileSync(scenarioFile, "utf8").trim();
if (process.env.STUB_SCENARIO === "usage") { process.stderr.write("usage: stub\n"); process.exit(2); }
if (process.env.STUB_SCENARIO === "none") { process.stderr.write("fatal: no summary\n"); process.exit(13); }
fs.mkdirSync(out, { recursive: true });
fs.writeFileSync(path.join(out, "stub-env-keys.json"), JSON.stringify(Object.keys(process.env)));
fs.writeFileSync(path.join(out, "stub-argv.json"), JSON.stringify(process.argv.slice(2)));
let n = 1;
for (const name of fs.readdirSync(out)) { const m = /^round-(\d+)$/.exec(name); if (m) n = Math.max(n, Number(m[1]) + 1); }
const round = path.join(out, `round-${String(n).padStart(3, "0")}`);
fs.cpSync(process.env.STUB_SCENARIO, round, { recursive: true });
const summaryFile = path.join(round, "round-summary.json");
const summary = JSON.parse(fs.readFileSync(summaryFile, "utf8"));
summary.roundDir = round;
summary.candidateCommit = candidate;
if (summary.harness?.resultsPath) summary.harness.resultsPath = path.join(round, "results.json");
fs.writeFileSync(summaryFile, JSON.stringify(summary, null, 2));
process.stdout.write(`ATD_STATUS=${summary.status}\nATD_SUMMARY=${summaryFile}\n`);
JS
}

# make_independent_keys <dir>: external key pair authorized for trust separate-user only.
make_independent_keys() {
  local d="$1"
  mkdir -p "$d"
  ssh-keygen -q -t ed25519 -N '' -f "$d/key" >/dev/null
  chmod 600 "$d/key"
  printf 'atd-runner-separate-user namespaces="atd-execution@v1" %s\n' "$(cut -d' ' -f1,2 "$d/key.pub")" > "$d/allowed"
}

# scenario_id <scenario-dir> -> the case id used inside it
scenario_id() {
  if [[ -f "$1/.case-id" ]]; then cat "$1/.case-id"; else printf 'case-%s' "$(basename "$1" | tr -c 'A-Za-z0-9._-' '-')"; fi
}

# scenario_approvals <scenario-dir> -> the TRUSTED operator approval directory for that scenario (outside the round).
# It only ever holds the review the operator really gave (verified-* kinds); forged/suspected scenarios get none.
scenario_approvals() { printf '%s/approvals/%s' "$FX_TMP" "$(basename "$1")"; }

# make_scenario <dir> <kind>
#   kinds: verified-independent | verified-local | suspected | inconclusive | clean | harness-error | no-candidates
# Independent kinds need $KEYS (make_independent_keys) and export ATD_ALLOWED_SIGNERS_FILE for replay (see below).
make_scenario() {
  local dir="$1" kind="$2" id build_args=() trust=local status=completed
  id="$(scenario_id "$dir")"
  mkdir -p "$dir"
  case "$kind" in
    verified-independent) build_args=(--base=pass --candidate=fail --review=approved); trust=independent ;;
    suspected-independent) build_args=(--base=pass --candidate=fail); trust=independent ;;
    verified-local)       build_args=(--base=pass --candidate=fail --review=approved) ;;
    suspected)            build_args=(--base=pass --candidate=fail) ;;
    inconclusive)         build_args=(--base=pass --candidate=fail --review=approved --env-diff) ;;
    clean)                build_args=(--base=pass --candidate=pass) ;;
    harness-error|no-candidates) status="$([[ "$kind" == "harness-error" ]] && echo harness_error || echo no_candidates)"; build_args=() ;;
    *) echo "make_scenario: unknown kind $kind" >&2; return 1 ;;
  esac

  if ((${#build_args[@]})); then
    # Attested revisions must equal the commit under evaluation (repair requests refuse stale evidence).
    [[ -z "${SCENARIO_BASE_COMMIT:-}" ]] || build_args+=(--base-commit="$SCENARIO_BASE_COMMIT")
    [[ -z "${SCENARIO_CANDIDATE_COMMIT:-}" ]] || build_args+=(--candidate-commit="$SCENARIO_CANDIDATE_COMMIT")
    if [[ "$trust" == independent ]]; then
      ( export ATD_TRUST=separate-user ATD_SIGNING_KEY_FILE="$KEYS/key" ATD_ALLOWED_SIGNERS_FILE="$KEYS/allowed"
        cd_="$(fx_case "$id")"; fx_build "$cd_/workdir" "${build_args[@]}"; fx_pipeline "$cd_" 3; fx_result "$cd_" > "$dir/case.json" )
    else
      ( cd_="$(fx_case "$id")"; fx_build "$cd_/workdir" "${build_args[@]}"; fx_pipeline "$cd_" 3; fx_result "$cd_" > "$dir/case.json" )
    fi
    mkdir -p "$dir/evidence"
    cp -R "$FX_TMP/runs/$FX_RUN_ID/$id" "$dir/evidence/$id"
    # The operator's original review (what a human actually approved) goes to the trusted approval store.
    mkdir -p "$(scenario_approvals "$dir")"
    if [[ -f "$dir/evidence/$id/workdir/expectation-review.json" ]]; then
      cp "$dir/evidence/$id/workdir/expectation-review.json" "$(scenario_approvals "$dir")/$(jq -r .candidateId "$dir/evidence/$id/workdir/expectation-review.json").expectation-review.json"
    fi
    build_run_summary "[$(cat "$dir/case.json")]" "$FX_RUN_ID" manual > "$dir/results.json"
  fi
  mkdir -p "$(scenario_approvals "$dir")"
  write_round_summary "$dir" "$status"
  printf '%s' "$id" > "$dir/.case-id"
}

# Building signed evidence (3 fresh sandbox-shaped samples) is slow, so each kind is built once and cloned. A clone keeps
# the case id (the attestation binds run/case ids) and gets its own copy of the trusted approval directory.
base_scenario() { local d="$FX_TMP/base/$1"; if [[ ! -d "$d" ]]; then mkdir -p "$FX_TMP/base"; make_scenario "$d" "$1"; fi; printf '%s' "$d"; }
scenario_from_kind() { # <dest> <kind>
  local src; src="$(base_scenario "$2")"
  rm -rf "$1"; cp -R "$src" "$1"
  rm -rf "$(scenario_approvals "$1")"; cp -R "$(scenario_approvals "$src")" "$(scenario_approvals "$1")"
}

# write_round_summary <dir> <status>: a summary shaped like run.mjs's, derived from results.json when present.
write_round_summary() {
  local dir="$1" status="$2" results="[]"
  if [[ -f "$dir/results.json" ]]; then results="$(jq -c '.cases' "$dir/results.json")"; fi
  jq -n --arg status "$status" --arg state "$EVAL_STATE_DIR" --argjson cases "$results" --argjson has "$([[ -f "$dir/results.json" ]] && echo true || echo false)" '
    ($cases | map({caseId:.case_id,status:.status,classification:(.discovery.classification // (if .status=="PASS" then "NO_FINDING" else "UNCLASSIFIED_NON_PASS" end))})) as $c
    | {schema:"atd.discovery-round/v1",status:$status,roundDir:"",candidateCommit:"",
       harness:(if $has then {verdict:"FAIL",resultsPath:"x",stateDir:$state} else {verdict:null} end),
       classificationCounts:($c | group_by(.classification) | map({key:.[0].classification,value:length}) | from_entries),
       nonPass:($c | map(select(.status!="PASS") | . + {failedChecks:[]})),
       cases:$c,findings:($cases | map(select(.discovery != null) | .discovery)),
       generation:{transport:"omp",real:true,servedModels:["anthropic/claude-sonnet-5-5"],modelCalls:1},
       candidates:{accepted:($cases|length),rejected:[]},
       errors:(if $status=="completed" or $status=="no_candidates" then [] else [{stage:"harness",code:"harness_error",message:"boom"}] end)}' > "$dir/round-summary.json"
}

# --- attacks on a preserved round (each is something an operator-less attacker with file access could do) ---------
# forge_results_to_verified <dir> <trust>: edit results.json/round summary so the finding CLAIMS an independent VERIFIED regression.
forge_results_to_verified() {
  local dir="$1" trust="$2"
  jq --arg t "$trust" '.cases[0].status="FAIL" | .cases[0].discovery.classification="VERIFIED_REGRESSION" | .cases[0].discovery.reproducible=true
      | .cases[0].discovery.evidenceStatus="valid" | .cases[0].discovery.requirementSupported=true | .cases[0].discovery.attestation.trust=$t' "$dir/results.json" > "$dir/results.tmp" && mv "$dir/results.tmp" "$dir/results.json"
  jq --arg t "$trust" '.verifiedIndependentFindingIds=["forged"] | .findings[0].classification="VERIFIED_REGRESSION" | .findings[0].attestation.trust=$t' "$dir/round-summary.json" > "$dir/rs.tmp" && mv "$dir/rs.tmp" "$dir/round-summary.json"
}
# tamper_artifact <dir>: modify a signed artifact after the fact.
tamper_artifact() { printf ' ' >> "$1/evidence/$(scenario_id "$1")/workdir/atd-out/base.json"; }
# drop_signature <dir>: delete the detached signature.
drop_signature() { rm -f "$1/evidence/$(scenario_id "$1")/workdir/atd-out/attestation.json.sig"; }
# drop_manifest <dir>: remove the preserved grading manifest.
drop_manifest() { rm -f "$1/evidence/$(scenario_id "$1")/grading-manifest.json"; }
# tamper_stability <dir>: edit the bound stability metadata so the samples no longer match the manifest.
tamper_stability() { jq '.samples=9' "$1/evidence/$(scenario_id "$1")/stability.json" > "$1/stab.tmp" && mv "$1/stab.tmp" "$1/evidence/$(scenario_id "$1")/stability.json"; }

# regen_manifest <dir>: an attacker with full write access and the production tooling rewrites the (unsigned, hash-only)
# grading manifest over the attacked preserved case so every digest matches again.
regen_manifest() {
  local id d; id="$(scenario_id "$1")"; d="$1/evidence/$id"
  write_case_grading_manifest "$d/case.yaml" "$d/workdir" "$d/transcript.jsonl" "$d/env-manifest.json" "$FX_RUN_ID" "$id" "$d/grading-manifest.json"
}
# forge_review_manifest_results <dir>: the operator never reviewed this case. The attacker writes a PASS review bound to the
# attested hashes, regenerates the manifest, and edits results.json/round summary to claim the matching independent VERIFIED.
forge_review_manifest_results() {
  local dir="$1" id wd; id="$(scenario_id "$dir")"; wd="$dir/evidence/$id/workdir"
  jq -n --slurpfile a "$wd/atd-out/attestation.json" '{schema_version:1,verdict:"PASS",reviewer:"attacker",rubric_version:"v1",timestamp:"2026-11-03T00:00:00Z",rationale:"forged",
    candidateId:$a[0].candidateId,testSha256:$a[0].testSha256,specSha256:$a[0].specSha256,candidateManifestSha256:$a[0].candidateManifestSha256}' > "$wd/expectation-review.json"
  regen_manifest "$dir"
  forge_results_to_verified "$dir" separate-user
}
# rewrite_review_manifest <dir>: the operator did approve, but the attacker changes the preserved review bytes and the manifest.
rewrite_review_manifest() {
  local dir="$1" id wd; id="$(scenario_id "$dir")"; wd="$dir/evidence/$id/workdir"
  jq '.rationale="rewritten by attacker" | .reviewer="attacker"' "$wd/expectation-review.json" > "$wd/review.tmp" && mv "$wd/review.tmp" "$wd/expectation-review.json"
  regen_manifest "$dir"
}
# inject_command_check <dir>: add an unsafe shell grader to the preserved case.yaml and regenerate the manifest.
# $SENTINEL is created by the command if (and only if) the host ever executes it.
inject_command_check() {
  local dir="$1" id; id="$(scenario_id "$dir")"
  cat >> "$dir/evidence/$id/case.yaml" <<YAML
  - kind: shell
    unsafe_shell: true
    cmd: "touch '$SENTINEL'"
    expect_min: 0
YAML
  regen_manifest "$dir"
}

# redirect_manifest_case_path <dir>: keep a benign case.yaml but point the rewritten manifest at evil.yaml (an unsafe shell
# grader with a valid digest). Without the binding check grade.sh would execute evil.yaml on the host.
redirect_manifest_case_path() {
  local dir="$1" id d evil; id="$(scenario_id "$dir")"; d="$dir/evidence/$id"
  cp "$d/case.yaml" "$d/evil.yaml"
  cat >> "$d/evil.yaml" <<YAML
  - kind: shell
    unsafe_shell: true
    cmd: "touch '$SENTINEL'"
    expect_min: 0
YAML
  jq --arg sha "$(shasum -a 256 "$d/evil.yaml" | cut -d' ' -f1)" '.case_file.path="evil.yaml" | .case_file.sha256=$sha' "$d/grading-manifest.json" > "$d/gm.tmp" && mv "$d/gm.tmp" "$d/grading-manifest.json"
}
# redirect_manifest_workdir <dir>: point the rewritten manifest at an alternate evidence tree (a copy of the workdir the
# attacker is free to edit) with a matching tree digest.
redirect_manifest_workdir() {
  local dir="$1" id d; id="$(scenario_id "$dir")"; d="$dir/evidence/$id"
  cp -R "$d/workdir" "$d/workdir2"
  jq --arg sha "$(portable_tree_sha256 "$d/workdir2")" '.evidence.workdir.path="workdir2" | .evidence.workdir.sha256=$sha' "$d/grading-manifest.json" > "$d/gm.tmp" && mv "$d/gm.tmp" "$d/grading-manifest.json"
}
# symlink_case_file <dir>: case.yaml replaced by a symlink to an out-of-tree file.
symlink_case_file() {
  local dir="$1" id d; id="$(scenario_id "$dir")"; d="$dir/evidence/$id"
  cp "$d/case.yaml" "$dir/outside-case.yaml"; rm -f "$d/case.yaml"; ln -s "$dir/outside-case.yaml" "$d/case.yaml"
}
