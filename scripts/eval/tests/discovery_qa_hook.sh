#!/usr/bin/env bash
# QA Factory oracle command-hook adapter (integrations/qa-factory/discovery.py) with a stubbed pipeline over REAL
# signed evidence. Verifies the JSON/namespace protocol, that classifications come from the independent grade.sh
# replay (never from results.json), honest mapping (local-same-user is advisory, CONFIRMED_DEFECT needs a recomputed
# independent signer), bounded I/O, scrubbed environment, idempotent operations, process-group cleanup on timeout,
# and (when a QA Factory checkout is available) the real qa_factory.hooks.command_hook consumer.
set -euo pipefail

QA_TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EH_ROOT="$(cd "$QA_TEST_DIR/../../.." && pwd)"
for tool in jq node git ssh-keygen yq python3; do command -v "$tool" >/dev/null 2>&1 || { echo "SKIP: $tool required" >&2; exit 0; }; done

# shellcheck source=lib/atd-fixture.sh
source "$QA_TEST_DIR/lib/atd-fixture.sh"
fx_init
WORK="$FX_TMP/work"; mkdir -p "$WORK"
trap 'rm -rf "$FX_TMP"' EXIT
# shellcheck source=lib/discovery_stub_round.sh
source "$QA_TEST_DIR/lib/discovery_stub_round.sh"

fail() { echo "FAIL: $*" >&2; exit 1; }
KEYS="$WORK/keys"; make_independent_keys "$KEYS"

# Fake evalHarnessRoot: a full copy of scripts/eval (grade.sh, libs, verifier, repair-request.mjs) with run.mjs stubbed.
FAKE="$WORK/eh"
mkdir -p "$FAKE/scripts" "$FAKE/integrations/qa-factory"
cp -R "$EH_ROOT/scripts/eval" "$FAKE/scripts/eval"
rm -rf "$FAKE/scripts/eval/tests"
install_stub_run_mjs "$FAKE/scripts/eval/discovery"
cp "$EH_ROOT/integrations/qa-factory/discovery.py" "$FAKE/integrations/qa-factory/discovery.py"
HOOK="$FAKE/integrations/qa-factory/discovery.py"

REPO="$WORK/repo"; mkdir -p "$REPO"; git -C "$REPO" init -q -b main
git -C "$REPO" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m one
export SCENARIO_CANDIDATE_COMMIT="$(git -C "$REPO" rev-parse HEAD)"
printf '# spec\n' > "$WORK/SPEC.md"
NODE="$(command -v node)"

write_config() { # <approvalDir>: trusted profile config (the approval directory is operator-owned, outside every round)
  jq -n --arg root "$FAKE" --arg out "$WORK/out" --arg state "$EVAL_STATE_DIR" --arg node "$NODE" --arg repo "$REPO" --arg spec "$WORK/SPEC.md" --arg approvals "$1" --arg cand "$SCENARIO_CANDIDATE_COMMIT" '{
    schema:"atd.qa-hook-config/v1",evalHarnessRoot:$root,outputRoot:$out,stateDir:$state,node:$node,timeoutSeconds:120,passEnv:["ATD_ALLOWED_SIGNERS_FILE"],
    profiles:{"collision-boundary":({repository:$repo,spec:$spec,framework:"node:test",defaultBase:"HEAD",defaultCandidate:$cand} + (if $approvals=="" then {} else {approvalDir:$approvals} end))}}' > "$WORK/config.json"
}
CONFIG="$WORK/config.json"
write_config ""

# hook <scenario> <payload-json>: runs the adapter exactly as QA's command_hook would (scrubbed env; the only extra
# variable is the operator-provided verifier allowed-signers file, forwarded because the config lists it in passEnv).
hook() {
  local scenario="$1" payload="$2"
  write_config "$(scenario_approvals "$scenario")"
  printf '%s' "$scenario" > "$FAKE/scripts/eval/discovery/scenario.path"
  set +e
  OUT="$(printf '%s' "$payload" | env -i PATH="$PATH" HOME="$HOME" LANG=C.UTF-8 TMPDIR="${TMPDIR:-/tmp}" SECRET_SHOULD_NOT_LEAK=1 ATD_ALLOWED_SIGNERS_FILE="$KEYS/allowed" "$HOOK" --config "$CONFIG" 2>"$WORK/stderr.txt")"
  RC=$?
  set -e
}
payload() { jq -nc --arg op "$1" --arg ns "${2:-ns-$1}" '{operation_id:$op,namespace:$ns,oracle_id:"collision-boundary"}'; }
scenario() { scenario_from_kind "$WORK/s-$1" "$2"; }

# 1. recomputed verified + independent signer -> FAIL / CONFIRMED_DEFECT with a repair recommendation
scenario verified verified-independent
hook "$WORK/s-verified" "$(payload op-verified)"
[[ "$RC" == "0" ]] || fail "verified: exit $RC $(cat "$WORK/stderr.txt")"
jq -e '.namespace=="ns-op-verified" and .verdict=="FAIL" and .classification=="CONFIRMED_DEFECT" and .reviewRequired==false
  and .findings[0].qaClassification=="CONFIRMED_DEFECT" and .findings[0].attestationTrust=="separate-user" and .findings[0].rawDiscoveryClassification=="VERIFIED_REGRESSION"
  and .recommendations[0].type=="repair_request" and .recommendations[0].attempt==1' <<<"$OUT" >/dev/null || fail "verified mapping: $OUT"

# 2. suspected -> INCONCLUSIVE / SUSPECTED_DEFECT, review required, never CONFIRMED
scenario suspected suspected
hook "$WORK/s-suspected" "$(payload op-suspected)"
jq -e '.verdict=="INCONCLUSIVE" and .classification=="SUSPECTED_DEFECT" and .reviewRequired==true and (.recommendations|length)==0' <<<"$OUT" >/dev/null || fail "suspected mapping: $OUT"

# 3. inconclusive finding is not a finding, and is not a pass
scenario inconclusive inconclusive
hook "$WORK/s-inconclusive" "$(payload op-inconclusive)"
jq -e '.verdict=="INCONCLUSIVE" and .classification==null and .reviewRequired==true and (.findings|length)==0' <<<"$OUT" >/dev/null || fail "inconclusive mapping: $OUT"

# 4. pipeline error -> INCONCLUSIVE with errors; never a pass and never CONFIRMED_DEFECT
scenario error harness-error
hook "$WORK/s-error" "$(payload op-error)"
jq -e '.verdict=="INCONCLUSIVE" and .classification==null and .reviewRequired==true and (.errors|length)>=1 and .status=="harness_error"' <<<"$OUT" >/dev/null || fail "error mapping: $OUT"

# 5. clean run -> PASS with the honest note
scenario clean clean
hook "$WORK/s-clean" "$(payload op-clean)"
jq -e '.verdict=="PASS" and .classification==null and .reviewRequired==false and (.note|contains("not mean the change is bug-free"))' <<<"$OUT" >/dev/null || fail "clean mapping: $OUT"

# 6. nothing executed -> NOT_RUN
scenario nocand no-candidates
hook "$WORK/s-nocand" "$(payload op-nocand)"
jq -e '.verdict=="NOT_RUN" and .classification==null' <<<"$OUT" >/dev/null || fail "no-candidate mapping: $OUT"

# 7. genuinely verified but only locally signed: reporting-only trust => SUSPECTED_DEFECT + review, never CONFIRMED/FAIL
scenario local verified-local
hook "$WORK/s-local" "$(payload op-local)"
jq -e '.verdict=="INCONCLUSIVE" and .classification=="SUSPECTED_DEFECT" and .reviewRequired==true and (.reviewReasons|join(" ")|contains("local-same-user"))
  and .findings[0].qaClassification=="SUSPECTED_DEFECT" and .findings[0].recomputedDiscoveryClassification=="VERIFIED_REGRESSION" and .findings[0].rawDiscoveryClassification=="VERIFIED_REGRESSION"
  and .counts.byRawDiscoveryClassification.VERIFIED_REGRESSION==1 and ([.recommendations[]|select(.type=="repair_request")]|length)==0 and ([.recommendations[]|select(.type=="human_review")]|length)==1' <<<"$OUT" >/dev/null || fail "local trust mapping: $OUT"

# 8. forged / tampered preserved evidence can never become a confirmed defect (raw class stays visible separately)
attack() { # <name> <mutator> <kind>
  scenario "attack-$1" "$3"; "$2" "$WORK/s-attack-$1"
  hook "$WORK/s-attack-$1" "$(payload "op-attack-$1")"
  [[ "$RC" == "0" ]] || fail "attack $1: exit $RC $(cat "$WORK/stderr.txt")"
  jq -e '.verdict!="FAIL" and .classification!="CONFIRMED_DEFECT" and .reviewRequired==true and ([.findings[]|select(.qaClassification=="CONFIRMED_DEFECT")]|length)==0 and (.counts.unverifiedOrInconsistent>=1)' <<<"$OUT" >/dev/null || fail "attack $1 must not confirm a defect: $OUT"
}
forge_local_as_ci() { forge_results_to_verified "$1" ci-secret; }
attack forged-trust forge_local_as_ci verified-local
jq -e '(.reviewReasons|join(" ")|contains("disagree"))' <<<"$OUT" >/dev/null || fail "forged trust must be flagged as disagreeing: $OUT"
attack tampered-artifact tamper_artifact verified-independent
attack missing-signature drop_signature verified-independent
attack missing-manifest drop_manifest verified-independent
attack tampered-stability tamper_stability verified-independent

# 8b. unsigned preserved manifest/review/case are hash-bound only: rewriting them together must not confirm a defect, and an
#     injected grader must never execute on the host (sentinel).
SENTINEL="$WORK/host-command-ran"; rm -f "$SENTINEL"
unconfirmed() { # <name>
  jq -e '.verdict=="INCONCLUSIVE" and .classification!="CONFIRMED_DEFECT" and .reviewRequired==true and ([.findings[]|select(.qaClassification=="CONFIRMED_DEFECT")]|length)==0' <<<"$OUT" >/dev/null || fail "$1 must stay unconfirmed: $OUT"
}
scenario forged-review suspected-independent
forge_review_manifest_results "$WORK/s-forged-review"
hook "$WORK/s-forged-review" "$(payload op-forged-review)"
unconfirmed forged-review
scenario rewritten-review verified-independent
rewrite_review_manifest "$WORK/s-rewritten-review"
hook "$WORK/s-rewritten-review" "$(payload op-rewritten-review)"
unconfirmed rewritten-review
scenario injected-check verified-independent
inject_command_check "$WORK/s-injected-check"
hook "$WORK/s-injected-check" "$(payload op-injected-check)"
unconfirmed injected-check
[[ ! -e "$SENTINEL" ]] || fail "an injected grader executed a command on the host"

scenario alt-case-path verified-independent
redirect_manifest_case_path "$WORK/s-alt-case-path"
hook "$WORK/s-alt-case-path" "$(payload op-alt-case-path)"
unconfirmed alt-case-path
[[ ! -e "$SENTINEL" ]] || fail "a manifest-selected alternate case file executed a command on the host"
scenario alt-workdir verified-independent
redirect_manifest_workdir "$WORK/s-alt-workdir"
hook "$WORK/s-alt-workdir" "$(payload op-alt-workdir)"
unconfirmed alt-workdir

# the verifier without the independent allowed signers cannot confirm an external signature
scenario nokey verified-independent
write_config "$(scenario_approvals "$WORK/s-nokey")"
printf '%s' "$WORK/s-nokey" > "$FAKE/scripts/eval/discovery/scenario.path"
set +e
OUT="$(printf '%s' "$(payload op-nokey)" | env -i PATH="$PATH" HOME="$HOME" LANG=C.UTF-8 TMPDIR="${TMPDIR:-/tmp}" "$HOOK" --config "$CONFIG" 2>/dev/null)"; RC=$?
set -e
jq -e '.classification!="CONFIRMED_DEFECT" and .verdict!="FAIL" and .reviewRequired==true' <<<"$OUT" >/dev/null || fail "no verifier allowed-signers must not confirm: $OUT"

# 9. environment scrubbing and argv are controlled by config, not by the request
KEYS_SEEN="$(jq -c '.' "$WORK/out/operations/collision-boundary/op-clean/discovery/stub-env-keys.json")"
[[ "$KEYS_SEEN" != *SECRET_SHOULD_NOT_LEAK* ]] || fail "adapter leaked a non-allowlisted environment variable"
jq -e 'index("--framework=node:test")!=null and (map(select(startswith("--repo=")))|length)==1' "$WORK/out/operations/collision-boundary/op-clean/discovery/stub-argv.json" >/dev/null || fail "unexpected pipeline argv"

# 10. idempotent per operation_id: a second call returns the stored result without a new pipeline round
hook "$WORK/s-clean" "$(payload op-clean)"
[[ "$(ls "$WORK/out/operations/collision-boundary/op-clean/discovery" | grep -c '^round-')" == "1" ]] || fail "operation was re-run"
jq -e '.verdict=="PASS"' <<<"$OUT" >/dev/null || fail "stored result not returned"

# 11. protocol errors exit non-zero and emit no JSON (there is no start/status/worker machinery to select)
for bad in '{"operation_id":"x","oracle_id":"collision-boundary"}' '{"namespace":"n","operation_id":"../x","oracle_id":"collision-boundary"}' '{"namespace":"n","operation_id":"op-x","oracle_id":"nope"}' '{"namespace":"n","operation_id":"op-y","oracle_id":"collision-boundary","base":"--evil"}' 'not json'; do
  hook "$WORK/s-clean" "$bad"
  [[ "$RC" != "0" && -z "$OUT" ]] || fail "protocol error must fail without output: $bad (rc=$RC out=$OUT)"
done
big="$(python3 -c "print('{\"namespace\":\"n\",\"operation_id\":\"op-big\",\"oracle_id\":\"collision-boundary\",\"pad\":\"' + 'x'*70000 + '\"}')")"
hook "$WORK/s-clean" "$big"; [[ "$RC" != "0" ]] || fail "oversized input must be rejected"
set +e; "$HOOK" --config relative.json </dev/null >/dev/null 2>&1; rc=$?; set -e; [[ "$rc" == "2" ]] || fail "relative --config must exit 2"

# 12. output stays under QA's 64 KiB boundary even with many findings
scenario big suspected
jq '.findings = [range(0;60) as $i | .findings[0] + {findingId:("f\($i)"), explanation:("e" * 3000)}]' "$WORK/s-big/round-summary.json" > "$WORK/s-big/rs.tmp" && mv "$WORK/s-big/rs.tmp" "$WORK/s-big/round-summary.json"
hook "$WORK/s-big" "$(payload op-big-out)"
[[ "$RC" == "0" ]] || fail "big output run failed"
[[ "${#OUT}" -lt 65536 ]] || fail "adapter output exceeded 64 KiB (${#OUT})"
jq -e '.classification=="SUSPECTED_DEFECT"' <<<"$OUT" >/dev/null || fail "big output lost classification"

# 13. bounded process runner: streaming output stays bounded, and a timeout takes the whole process group down
cat > "$WORK/runner_check.py" <<'PY'
import importlib.util, os, sys, time
spec = importlib.util.spec_from_file_location("atd_discovery_hook", sys.argv[1])
mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
pidfile = sys.argv[2]
code, out, err, timed_out = mod.run_bounded([sys.executable, "-c", "import sys; sys.stdout.write('x' * 5_000_000); sys.stderr.write('y' * 3_000_000)"], dict(os.environ), 30)
assert code == 0 and not timed_out, (code, timed_out)
assert len(out) <= mod.TAIL_BYTES + 8192 and len(err) <= mod.TAIL_BYTES + 8192, (len(out), len(err))
mod.TERM_GRACE_SECONDS = 5
start = time.time()
code, out, err, timed_out = mod.run_bounded(["sh", "-c", f"sleep 300 & echo $! > {pidfile}; echo started; sleep 300"], dict(os.environ), 2)
assert timed_out, "timeout expected"
assert time.time() - start < 25, "timeout handling took too long"
child = int(open(pidfile).read().strip())
time.sleep(0.5)
try:
    os.kill(child, 0)
    alive = True
except ProcessLookupError:
    alive = False
assert not alive, "a grandchild survived the timeout"
print("runner ok")
PY
python3 "$WORK/runner_check.py" "$HOOK" "$WORK/child.pid" >/dev/null || fail "bounded runner check failed"

# 14. the real QA Factory consumer, when a checkout with its dependencies is available
QA_SRC="${QA_FACTORY_SRC:-$EH_ROOT/../qa-agents-factory/src}"
QA_PY="${QA_FACTORY_PYTHON:-$QA_SRC/../.venv/bin/python}"
if [[ -d "$QA_SRC/qa_factory" && -x "$QA_PY" ]] && "$QA_PY" -c "import sys; sys.path.insert(0, '$QA_SRC'); import qa_factory.hooks" >/dev/null 2>&1; then
  write_config "$(scenario_approvals "$WORK/s-verified")"
  printf '%s' "$WORK/s-verified" > "$FAKE/scripts/eval/discovery/scenario.path"
  RESULT="$(ATD_ALLOWED_SIGNERS_FILE="$KEYS/allowed" "$QA_PY" "$EH_ROOT/integrations/qa-factory/command_hook_smoke.py" --qa-src "$QA_SRC" \
    --hook-command-json "$(jq -nc --arg h "$HOOK" --arg c "$CONFIG" '[$h,"--config",$c]')" \
    --payload-json "$(payload op-qa-real ns-qa-real)" --hook-seconds 120 --secret-env ATD_ALLOWED_SIGNERS_FILE)" || fail "qa_factory command_hook rejected the adapter"
  jq -e '.namespace=="ns-qa-real" and .classification=="CONFIRMED_DEFECT"' <<<"$RESULT" >/dev/null || fail "command_hook result: $RESULT"
  echo "qa_factory.hooks.command_hook consumer: OK"
else
  echo "NOTE: qa-agents-factory checkout/venv not found; the real command_hook consumer check was not run" >&2
fi

echo "PASS discovery_qa_hook"
