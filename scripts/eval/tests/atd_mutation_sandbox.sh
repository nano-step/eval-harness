#!/usr/bin/env bash
# atd_mutation_sandbox: mutation testing (Stryker) only ever runs inside the same fail-closed container
# profile, under a hard per-run mutant budget. A stand-in `stryker.js` inside a throwaway dependency
# snapshot reports what it can observe from inside the sandbox (read-only revision export and
# dependencies, writable tmpfs working copy, overlaid tests) and drives the REAL trusted budget reporter
# plugin (sandbox-container/atd-budget-reporter.mjs) through the official reporter hook. Signed
# record/report/budget artifacts come back through the same attestation path. Over-budget plans exit 86
# before any mutant would run and are recorded as error/budget_exceeded, never as success.
# SKIPs without Docker + the pinned image (real Stryker is exercised separately with a dependency snapshot).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/atd/fixture.sh"
source "$ATD_FX_EVAL_DIR/lib/atd_attest.sh"
atd_fx_skip_unless_sandbox

TMP="$(mktemp -d -t atd-mutation.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
export EVAL_STATE_DIR="$TMP/state"
unset ATD_TRUST ATD_SIGNING_KEY_FILE ATD_ALLOWED_SIGNERS_FILE EVAL_ATD_POLICY DOCKER_HOST || true
NODE="$(atd_resolve_node)"
SANDBOX="$ATD_FX_EVAL_DIR/discovery/sandbox.mjs"
atd_fx_new_repo "$TMP/repo"

SNAP="$TMP/deps"; mkdir -p "$SNAP/node_modules/@stryker-mutator/core/bin" "$SNAP/node_modules/@stryker-mutator/api"
printf '{"lockfileVersion":3,"packages":{}}\n' > "$SNAP/package-lock.json"
printf '{"name":"@stryker-mutator/api","version":"0.0.0","type":"module","exports":{"./plugin":"./plugin.mjs"}}\n' > "$SNAP/node_modules/@stryker-mutator/api/package.json"
cat > "$SNAP/node_modules/@stryker-mutator/api/plugin.mjs" <<'EOF'
export const PluginKind = { Reporter: 'Reporter' };
export const declareValuePlugin = (kind, name, value) => ({ kind, name, value });
EOF
cat > "$SNAP/node_modules/@stryker-mutator/core/bin/stryker.js" <<'EOF'
const fs = require('node:fs');
const { spawn } = require('node:child_process');
const { pathToFileURL } = require('node:url');
const args = process.argv.slice(2);
const cfg = JSON.parse(fs.readFileSync(args[1], 'utf8'));
const attempt = (file) => { try { fs.writeFileSync(file, 'mutant'); return 'allowed'; } catch (e) { return e.code; } };
(async () => {
  const plans = Array.from({ length: cfg.fakePlans ?? 3 }, (_, i) => ({ mutant: { id: String(i) } }));
  if (cfg.fakeOrphan) spawn('sleep', ['600'], { detached: true, stdio: 'inherit' }).unref(); // holds the inherited pipes
  const loaded = [];
  for (const p of cfg.plugins) if (p.startsWith('.')) loaded.push(...(await import(pathToFileURL(require('node:path').resolve(p)).href)).strykerPlugins);
  const reporters = loaded.filter((p) => p.kind === 'Reporter' && cfg.reporters.includes(p.name)).map((p) => p.value);
  if (!cfg.fakeSkipHook) for (const r of reporters) r.onMutationTestingPlanReady({ mutantPlans: plans });
  const report = {
    schemaVersion: '2', thresholds: { high: 80, low: 60 },
    files: { 'src/clamp.mjs': { language: 'javascript', source: '', mutants: plans.map((p) => ({ id: p.mutant.id, mutatorName: 'x', status: 'Killed', location: { start: { line: 1, column: 1 }, end: { line: 1, column: 2 } } })) } },
    probe: {
      argv: args,
      reporters: cfg.reporters, pluginsHaveBudget: cfg.plugins.includes('./atd-budget-reporter.mjs'), incremental: cfg.incremental,
      revisionExportWrite: attempt('/src/src/clamp.mjs'),
      workingCopyWrite: attempt('/work/src/clamp.mjs'),
      nodeModulesWrite: attempt('/work/node_modules/.vite-temp-probe'),
      depsWrite: attempt('/deps/node_modules/@stryker-mutator/core/bin/stryker.js'),
      testsOverlaid: fs.existsSync('/work/tests/clamp.test.mjs'),
      secretVars: Object.keys(process.env).filter((k) => /KEY|TOKEN|SECRET/i.test(k)),
      psShim: require('node:child_process').spawnSync('ps', ['-o', 'pid', '--no-headers', '--ppid', '1']).status,
    },
  };
  fs.writeFileSync(cfg.jsonReporter.fileName, JSON.stringify(report));
})();
EOF
printf '{"mutate":["src/clamp.mjs"],"testRunner":"command","reporters":["html","progress"],"plugins":["@stryker-mutator/*"],"fakePlans":3}\n' > "$TMP/stryker.conf.json"
mkdir -p "$TMP/tests"; printf '%s' "$ATD_FX_TEST_UPPER_BOUNDARY" > "$TMP/tests/clamp.test.mjs"

mutate() { # <out> [extra args...] ; sets RC
  local out="$1"; shift
  RC=0
  ANTHROPIC_API_KEY=sk-canary "$NODE" "$SANDBOX" mutation --repository="$ATD_FX_REPO" --commit="$SHA_GOOD" --dependencies="${DEPS:-$SNAP}" --config="${CONF:-$TMP/stryker.conf.json}" --tests-dir="$TMP/tests" --tests-rel=tests --timeout=120 --out="$out" "$@" >"$TMP/mut.stdout" 2>"$TMP/mut.stderr" || RC=$?
}

echo "== within budget: confined run, pinned reporters, signed evidence =="
OUT="$TMP/mutation-out"
mutate "$OUT" --candidate-id=mut-1
[[ "$RC" == "0" ]] && atd_fx_pass "mutation run completed (exit 0) under the default budget" || { atd_fx_fail "mutation run exit $RC: $(tail -3 "$TMP/mut.stderr")"; atd_fx_finish; }
REPORT="$OUT/artifacts/mutant.mutation-report.json"
[[ -f "$REPORT" ]] && atd_fx_pass "Stryker report collected as a hashed artifact" || atd_fx_fail "report artifact missing: $(ls -R "$OUT")"
p() { jq -r ".probe.$1" "$REPORT"; }
[[ "$(p revisionExportWrite)" == "EROFS" ]] && atd_fx_pass "revision export mount is read-only" || atd_fx_fail "revision export writable: $(p revisionExportWrite)"
[[ "$(p workingCopyWrite)" == "allowed" && "$(p nodeModulesWrite)" == "allowed" ]] && atd_fx_pass "mutations and Vite temp files go to the tmpfs working copy" || atd_fx_fail "working copy: $(p workingCopyWrite)/$(p nodeModulesWrite)"
[[ "$(p depsWrite)" == "EROFS" ]] && atd_fx_pass "dependency snapshot is read-only during mutation" || atd_fx_fail "deps writable: $(p depsWrite)"
[[ "$(p testsOverlaid)" == "true" ]] && atd_fx_pass "test overlay present in the working copy" || atd_fx_fail "tests missing"
[[ "$(p reporters)" == '["json","atd-budget"]' || "$(jq -c .probe.reporters "$REPORT")" == '["json","atd-budget"]' ]] && atd_fx_pass "trusted wrapper pinned reporters to json+atd-budget (config html/progress dropped)" || atd_fx_fail "reporters: $(jq -c .probe.reporters "$REPORT")"
[[ "$(p pluginsHaveBudget)" == "true" && "$(p incremental)" == "false" ]] && atd_fx_pass "budget plugin forced into the effective config; incremental off" || atd_fx_fail "plugin/incremental: $(p pluginsHaveBudget)/$(p incremental)"
[[ "$(p psShim)" == "0" ]] && atd_fx_pass "process-listing stand-in available for Stryker's process-tree cleanup" || atd_fx_fail "ps shim status $(p psShim)"
[[ "$(jq -r '.probe.secretVars|length' "$REPORT")" == "0" ]] && atd_fx_pass "no credential variables inside the mutation container" || atd_fx_fail "secrets leaked: $(jq -c .probe.secretVars "$REPORT")"
[[ "$(git -C "$ATD_FX_REPO" show "$SHA_GOOD:src/clamp.mjs" | head -1)" == "export function clamp(value, lo, hi) {" ]] && atd_fx_pass "repository revision untouched" || atd_fx_fail "repository content changed"
BUDGET="$OUT/artifacts/mutant.mutation-budget.json"
[[ -f "$BUDGET" ]] && jq -e '.schema=="atd.mutation-budget/v1" and .maxMutants==100 and .planned==3 and .allowed==true' "$BUDGET" >/dev/null && atd_fx_pass "budget artifact recorded: max 100, planned 3, allowed" || atd_fx_fail "budget artifact: $(cat "$BUDGET" 2>/dev/null)"
atd_fx_verify_json "$OUT"
[[ "$ATD_FX_VRC" == "0" ]] && jq -e '.executionIds|length==1' <<<"$ATD_FX_VJSON" >/dev/null && atd_fx_pass "mutation evidence is signed and verifies" || atd_fx_fail "mutation evidence: $ATD_FX_VJSON"
jq -e '.side=="mutant" and .outcome=="pass" and .framework=="stryker" and .revision.commit=="'"$SHA_GOOD"'" and .env.ATD_MAX_MUTANTS=="100" and (.argv|index("--max-mutants=100")!=null) and .mutationBudget.maxMutants==100 and .mutationBudget.planned==3 and (.artifacts|map(.role)|index("mutation_budget")!=null)' "$OUT/mutant.json" >/dev/null && atd_fx_pass "record binds the budget in env, argv, mutationBudget and a mutation_budget artifact" || atd_fx_fail "record: $(jq -c 'del(.artifacts)' "$OUT/mutant.json")"
cp "$BUDGET" "$TMP/budget.bak"; echo '{"schema":"atd.mutation-budget/v1","maxMutants":100,"planned":1,"allowed":true}' > "$BUDGET"
atd_fx_verify_json "$OUT"; [[ "$ATD_FX_VRC" == "1" ]] && atd_fx_pass "a rewritten budget artifact invalidates the evidence" || atd_fx_fail "tampered budget verified"
echo '{"tampered":true}' > "$REPORT"
atd_fx_verify_json "$OUT"; [[ "$ATD_FX_VRC" == "1" ]] && atd_fx_pass "a swapped Stryker report invalidates the evidence" || atd_fx_fail "tampered report verified"

echo "== over budget: refused before any mutant runs =="
OVER="$TMP/mutation-over"
mutate "$OVER" --candidate-id=mut-2 --max-mutants=2
[[ "$RC" == "1" ]] && atd_fx_pass "over-budget plan => non-zero CLI exit (not 13: evidence exists)" || atd_fx_fail "over-budget exit $RC: $(tail -3 "$TMP/mut.stderr")"
jq -e '.outcome=="error" and .errorClass=="budget_exceeded" and .exitCode==86 and .mutationBudget.planned==3 and .mutationBudget.allowed==false and .mutationBudget.maxMutants==2' "$OVER/mutant.json" >/dev/null && atd_fx_pass "record: error/budget_exceeded, exit 86, planned 3 > max 2" || atd_fx_fail "over-budget record: $(jq -c 'del(.artifacts)' "$OVER/mutant.json")"
jq -e '(.artifacts|map(.role)|index("stryker_report")==null) and (.artifacts|map(.role)|index("mutation_budget")!=null)' "$OVER/mutant.json" >/dev/null && atd_fx_pass "refusal evidence carries the budget artifact and NO mutation report" || atd_fx_fail "over-budget artifacts: $(jq -c '[.artifacts[].role]' "$OVER/mutant.json")"
atd_fx_verify_json "$OVER"; [[ "$ATD_FX_VRC" == "0" ]] && atd_fx_pass "refusal evidence is itself signed and verifies" || atd_fx_fail "refusal evidence: $ATD_FX_VJSON"

echo "== a guard bypass is never a success =="
printf '{"mutate":["src/clamp.mjs"],"plugins":["@stryker-mutator/*"],"fakePlans":5,"fakeSkipHook":true}\n' > "$TMP/bypass.conf.json"
CONF="$TMP/bypass.conf.json" mutate "$TMP/mutation-bypass" --candidate-id=mut-3 --max-mutants=2
jq -e '.outcome=="error" and .errorClass=="budget_exceeded" and .mutationBudget.reportedMutants==5' "$TMP/mutation-bypass/mutant.json" >/dev/null && atd_fx_pass "report with 5 mutants over a budget of 2 is error/budget_exceeded even when the reporter hook never ran" || atd_fx_fail "bypass record: $(jq -c 'del(.artifacts)' "$TMP/mutation-bypass/mutant.json" 2>/dev/null)"
printf '{"mutate":["src/clamp.mjs"],"plugins":["@stryker-mutator/*"],"fakePlans":1,"fakeSkipHook":true}\n' > "$TMP/nohook.conf.json"
CONF="$TMP/nohook.conf.json" mutate "$TMP/mutation-nohook" --candidate-id=mut-4
jq -e '.outcome=="error" and .errorClass=="infra"' "$TMP/mutation-nohook/mutant.json" >/dev/null && atd_fx_pass "a run whose budget reporter never executed is error/infra, not pass" || atd_fx_fail "no-hook record: $(jq -c 'del(.artifacts)' "$TMP/mutation-nohook/mutant.json" 2>/dev/null)"

echo "== orphaned workers can not stall the container after the exit-86 refusal =="
printf '{"mutate":["src/clamp.mjs"],"plugins":["@stryker-mutator/*"],"fakePlans":9,"fakeOrphan":true}\n' > "$TMP/orphan.conf.json"
start=$(date +%s)
CONF="$TMP/orphan.conf.json" mutate "$TMP/mutation-orphan" --candidate-id=mut-5 --max-mutants=2
elapsed=$(( $(date +%s) - start ))
jq -e '.errorClass=="budget_exceeded" and .timedOut==false' "$TMP/mutation-orphan/mutant.json" >/dev/null && atd_fx_pass "refused despite a worker holding the inherited pipes (not a timeout)" || atd_fx_fail "orphan record: $(jq -c 'del(.artifacts)' "$TMP/mutation-orphan/mutant.json" 2>/dev/null)"
[[ "$elapsed" -lt 60 ]] && atd_fx_pass "bounded cleanup (${elapsed}s, orphan sleeps 600s)" || atd_fx_fail "stalled ${elapsed}s behind an orphan"
own="$(atd_fx_own_containers "$TMP/mutation-orphan" "$TMP/mutation-orphan/mutant.json")"
[[ -f "$TMP/mutation-orphan/mutant.json" ]] || atd_fx_fail "orphan-case record missing; own-container check would be vacuous"
[[ "${own%% *}" == "0" ]] && atd_fx_pass "this run's mutation container (out-dir label and attested execution id) is removed" || atd_fx_fail "this run leaked containers: $own"

echo "== budget argument validation =="
for bad in 0 501 abc -1 1.5 ""; do
  RC=0; "$NODE" "$SANDBOX" mutation --repository="$ATD_FX_REPO" --commit="$SHA_GOOD" --dependencies="$SNAP" --config="$TMP/stryker.conf.json" --out="$TMP/mut-bad-budget" --max-mutants="$bad" >/dev/null 2>&1 || RC=$?
  [[ "$RC" == "13" && ! -e "$TMP/mut-bad-budget" ]] && atd_fx_pass "--max-mutants='$bad' refused (exit 13, no output)" || atd_fx_fail "--max-mutants='$bad' exit $RC"
done

if "$NODE" "$SANDBOX" mutation --repository="$ATD_FX_REPO" --commit=main --dependencies="$SNAP" --config="$TMP/stryker.conf.json" --out="$TMP/mut-bad" >/dev/null 2>&1; then
  atd_fx_fail "branch name accepted as --commit"; else atd_fx_pass "mutation refuses non-SHA commit"; fi
[[ ! -e "$TMP/mut-bad" ]] && atd_fx_pass "refused mutation leaves no output" || atd_fx_fail "output left behind"

atd_fx_finish
