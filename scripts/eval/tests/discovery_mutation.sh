#!/usr/bin/env bash
# Consumer-visible behavior of scripts/eval/discovery/mutation.mjs: scoped, deterministic Stryker
# configuration for the changed ranges; normalization of Stryker reports into killed / survived /
# equivalent / invalid outcomes where survivors are test-suite GAPS (never confirmed bugs); source
# preservation checks; surviving->killed comparison. The module never runs Stryker or any tests.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/portable.sh"
DISCOVERY="$SCRIPT_DIR/../discovery"
RISK="$DISCOVERY/risk.mjs"
MUTATION="$DISCOVERY/mutation.mjs"

command -v node >/dev/null 2>&1 || { echo "SKIP: node not available" >&2; exit 0; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git not available" >&2; exit 0; }

WORK="$(mktemp -d -t eval-harness-mut.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
REPO="$WORK/repo"

fail() { echo "FAIL: $*" >&2; exit 1; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
g() { git -C "$REPO" -c commit.gpgsign=false "$@"; }
sha256_of() { portable_sha256_file "$1" | cut -d' ' -f1; }
check() { jq -e "$2" "$1" >/dev/null || { echo "document $1:" >&2; cat "$1" >&2; fail "$3"; }; }

# --------------------------------------------------------------------------- fixture
mkdir -p "$REPO/src" "$REPO/test"
g init -q
cat > "$REPO/src/collision.ts" <<'EOF'
export interface Rect {
  x: number;
  y: number;
  width: number;
  height: number;
}

/** Axis-aligned overlap. Touching edges are not an overlap. */
export function overlaps(a: Rect, b: Rect): boolean {
  return a.x < b.x + b.width && a.x + a.width > b.x && a.y < b.y + b.height && a.y + a.height > b.y;
}
EOF
printf "import { expect, it } from 'vitest';\nimport { overlaps } from '../src/collision';\nit('x', () => { expect(overlaps({x:0,y:0,width:1,height:1},{x:5,y:5,width:1,height:1})).toBe(false); });\n" > "$REPO/test/collision.test.ts"
g add -A; g commit -q -m base
BASE="$(g rev-parse HEAD)"
awk '{ sub(/a\.x < b\.x \+ b\.width/, "a.x <= b.x + b.width"); print }' "$REPO/src/collision.ts" > "$WORK/c.ts" && cp "$WORK/c.ts" "$REPO/src/collision.ts"
g add -A; g commit -q -m "boundary change"
CAND="$(g rev-parse HEAD)"
node "$RISK" --repo="$REPO" --base="$BASE" --candidate="$CAND" --out="$WORK/risk.json"
RET="$(grep -n 'return a.x' "$REPO/src/collision.ts" | cut -d: -f1)"
FN_START="$(jq -r '.targets[0].symbolRanges[0].startLine' "$WORK/risk.json")"
FN_END="$(jq -r '.targets[0].symbolRanges[0].endLine' "$WORK/risk.json")"
SOURCE_SHA="$(sha256_of "$REPO/src/collision.ts")"

# a second change (different diff) and a formatting-only change (no targets)
g checkout -q -B second "$BASE"
awk '{ sub(/a\.y < b\.y \+ b\.height/, "a.y <= b.y + b.height"); print }' "$REPO/src/collision.ts" > "$WORK/c2.ts" && cp "$WORK/c2.ts" "$REPO/src/collision.ts"
g add -A; g commit -q -m second
SECOND="$(g rev-parse HEAD)"
node "$RISK" --repo="$REPO" --base="$BASE" --candidate="$SECOND" --out="$WORK/risk2.json"
g checkout -q -B fmt "$BASE"
printf '// only a comment\n%s\n' "$(cat "$REPO/src/collision.ts")" > "$REPO/src/collision.ts"
g add -A; g commit -q -m fmt
FMT="$(g rev-parse HEAD)"
node "$RISK" --repo="$REPO" --base="$BASE" --candidate="$FMT" --out="$WORK/risk-empty.json"
check "$WORK/risk-empty.json" '.targets == []' "fixture: formatting-only report must be empty"
g checkout -q "$CAND" 2>/dev/null

# --------------------------------------------------------------------------- 1. scoped Stryker config (vitest)
node "$MUTATION" config --risk="$WORK/risk.json" --framework=vitest --out-dir="$WORK/plan1" > "$WORK/config-out.json" \
  || fail "config command failed"
C="$WORK/plan1/stryker.config.json"
P="$WORK/plan1/mutation-plan.json"
check "$C" ".mutate == [\"src/collision.ts:$RET-$RET\"]" "mutation scoped to the changed line only"
check "$C" '.testRunner == "vitest" and (.plugins | index("@stryker-mutator/vitest-runner") != null) and .coverageAnalysis == "perTest"' "maintained Vitest runner with per-test coverage"
check "$C" '.inPlace == false and .reporters == ["json","atd-budget"] and .jsonReporter.fileName == "reports/mutation/mutation.json" and .incremental == false' "sandbox copy, JSON report, no incremental state"
check "$C" '.concurrency == 1 and .timeoutMS == 5000 and (.ignorePatterns | index("atd-out") != null)' "deterministic, bounded run settings"
check "$C" 'has("commandRunner") | not' "no command runner for vitest"
check "$P" '.schema == "atd.mutation-plan/v1" and .hostExecution == "forbidden" and .requiresConfinement == true' "plan forbids host execution"
check "$P" '.argv == ["node","node_modules/@stryker-mutator/core/bin/stryker.js","run","stryker.config.json"]' "in-sandbox argv uses the maintained Stryker CLI"
check "$P" ".baseCommit == \"$BASE\" and .candidateCommit == \"$CAND\" and .diffSha256 == \"$(jq -r .diffSha256 "$WORK/risk.json")\"" "plan provenance"
check "$P" '.maxMutants == 100' "default mutant budget"
check "$C" '.plugins | index("./atd-budget-reporter.mjs") != null and index("@stryker-mutator/vitest-runner") != null' "trusted budget reporter plugin registered beside the maintained runner"
check "$C" 'has("maxMutants") | not' "budget lives in the plan, not in unknown Stryker options"
check "$P" '(.seed | type) == "number" and .env.ATD_SEED == (.seed | tostring) and .env.FC_SEED == .env.ATD_SEED' "seed recorded and injected via ATD_SEED/FC_SEED"
check "$P" '.files == [{"file":"src/collision.ts","symbols":["overlaps"],"ranges":[{"startLine":'"$RET"',"endLine":'"$RET"'}]}]' "per-file scope recorded"
jq -S . "$C" > "$WORK/a.json"; jq -S .strykerConfig "$P" > "$WORK/b.json"
cmp -s "$WORK/a.json" "$WORK/b.json" || fail "stryker.config.json differs from plan.strykerConfig"
check "$P" ".configSha256 | test(\"^[0-9a-f]{64}\$\")" "config hash recorded"
[[ ! -e "$WORK/plan1/.stryker-tmp" && ! -e "$WORK/plan1/reports" ]] || fail "config generation must not run Stryker"

node "$MUTATION" config --risk="$WORK/risk.json" --framework=vitest --out-dir="$WORK/plan1b" >/dev/null
cmp -s "$C" "$WORK/plan1b/stryker.config.json" && cmp -s "$P" "$WORK/plan1b/mutation-plan.json" || fail "plan is not deterministic"
node "$MUTATION" config --risk="$WORK/risk2.json" --framework=vitest --out-dir="$WORK/plan2" >/dev/null
[[ "$(jq -r .seed "$P")" != "$(jq -r .seed "$WORK/plan2/mutation-plan.json")" ]] || fail "different diffs must derive different seeds"
node "$MUTATION" config --risk="$WORK/risk.json" --framework=vitest --seed=42 --out-dir="$WORK/plan3" >/dev/null
check "$WORK/plan3/mutation-plan.json" '.seed == 42 and .env.ATD_SEED == "42" and .env.FC_SEED == "42"' "explicit seed honoured"

node "$MUTATION" config --risk="$WORK/risk.json" --framework=vitest --scope=symbols --out-dir="$WORK/plan4" >/dev/null
check "$WORK/plan4/stryker.config.json" ".mutate == [\"src/collision.ts:$FN_START-$FN_END\"]" "symbols scope mutates the changed function"
node "$MUTATION" config --risk="$WORK/risk.json" --framework=vitest --vitest-config=vitest.config.ts --typescript-checker --tsconfig=tsconfig.json --exclude-mutations=StringLiteral,BlockStatement --out-dir="$WORK/plan5" >/dev/null
check "$WORK/plan5/stryker.config.json" '.vitest.configFile == "vitest.config.ts" and .checkers == ["typescript"] and .tsconfigFile == "tsconfig.json" and .mutator.excludedMutations == ["BlockStatement","StringLiteral"] and (.plugins | index("@stryker-mutator/typescript-checker") != null)' "optional checker/exclusions configured"

# mutant budget: default 100, explicit values honoured, hard maximum 500
node "$MUTATION" config --risk="$WORK/risk.json" --framework=vitest --max-mutants=250 --out-dir="$WORK/plan-budget" > "$WORK/budget-out.json"
check "$WORK/plan-budget/mutation-plan.json" '.maxMutants == 250' "explicit mutant budget recorded"
check "$WORK/budget-out.json" '.maxMutants == 250' "CLI reports the budget"
node "$MUTATION" config --risk="$WORK/risk.json" --framework=vitest --max-mutants=500 --out-dir="$WORK/plan-budget-max" >/dev/null
check "$WORK/plan-budget-max/mutation-plan.json" '.maxMutants == 500' "hard maximum accepted"
node "$MUTATION" config --risk="$WORK/risk.json" --framework=vitest --max-mutants=1 --out-dir="$WORK/plan-budget-min" >/dev/null
check "$WORK/plan-budget-min/mutation-plan.json" '.maxMutants == 1' "minimum budget accepted"
for bad in 0 501 1000000 abc -1 1.5 ''; do
  if node "$MUTATION" config --risk="$WORK/risk.json" --framework=vitest "--max-mutants=$bad" --out-dir="$WORK/plan-budget-bad" 2>/dev/null; then
    fail "--max-mutants=$bad must be rejected"
  fi
  [[ ! -e "$WORK/plan-budget-bad" ]] || fail "rejected budget must not write files (--max-mutants=$bad)"
done
OUT="$(node --input-type=module -e '
const { createMutationPlan } = await import(process.argv[1]);
const risk = JSON.parse(process.argv[2]);
const ok = createMutationPlan({ riskReport: risk, framework: "vitest" }).maxMutants;
let rejected = 0;
for (const v of [0, 501, 1.5, "100", null, Infinity, NaN]) { try { createMutationPlan({ riskReport: risk, framework: "vitest", maxMutants: v }); } catch (e) { if (e.code === "usage") rejected += 1; } }
console.log(JSON.stringify({ ok, rejected }));
' "file://$DISCOVERY/mutation.mjs" "$(cat "$WORK/risk.json")")" || fail "programmatic createMutationPlan failed"
[[ "$(jq -c . <<<"$OUT")" == '{"ok":100,"rejected":7}' ]] || fail "programmatic budget validation unexpected: $OUT"

# node:test uses the command runner
node "$MUTATION" config --risk="$WORK/risk.json" --framework=node:test --tests=test/a.test.mjs,test/b.test.mjs --out-dir="$WORK/plan6" >/dev/null
check "$WORK/plan6/stryker.config.json" '.testRunner == "command" and .commandRunner.command == "node --test test/a.test.mjs test/b.test.mjs" and .coverageAnalysis == "off" and .plugins == ["./atd-budget-reporter.mjs"]' "node:test runs through the command runner with only the trusted budget reporter plugin"
if node "$MUTATION" config --risk="$WORK/risk.json" --framework=node:test --out-dir="$WORK/plan7" 2>/dev/null; then
  fail "node:test without test paths must be rejected"
fi
for bad in '../x.test.js' 'a b.test.js' 'x;rm.test.js' '$(id).test.js' '/abs/x.test.js' 'plain.js'; do
  if node "$MUTATION" config --risk="$WORK/risk.json" --framework=node:test "--tests=$bad" --out-dir="$WORK/plan-bad" 2>/dev/null; then
    fail "unsafe test path $bad must be rejected"
  fi
  [[ ! -e "$WORK/plan-bad" ]] || fail "rejected config must not write files ($bad)"
done
if node "$MUTATION" config --risk="$WORK/risk.json" --framework=vitest '--exclude-mutations=Foo;Bar' --out-dir="$WORK/plan-bad" 2>/dev/null; then
  fail "unsafe mutator names must be rejected"
fi
if node "$MUTATION" config --risk="$WORK/risk-empty.json" --framework=vitest --out-dir="$WORK/plan-empty" 2>"$WORK/err.txt"; then
  fail "a risk report without targets has nothing to mutate"
fi
grep -q 'no_targets' "$WORK/err.txt" || fail "no_targets not reported"
if node "$MUTATION" config --risk="$WORK/risk.json" --framework=jest --out-dir="$WORK/plan-bad" 2>/dev/null; then fail "unknown framework rejected"; fi

# --------------------------------------------------------------------------- 2. report normalization
col_of() { awk -v n="$RET" -v s="$1" 'NR == n { print index($0, s) }' "$REPO/src/collision.ts"; }
LT="$(col_of '<=')"
PLUS="$(( $(col_of ' + ') + 1 ))"
GT="$(( $(col_of ' > ') + 1 ))"
g show "$CAND:src/collision.ts" > "$WORK/candidate-source.ts"
raw_report() { # source-file; ids offset ; outcome set by $2 (before|after)
  local src="$1" variant="$2"
  jq -n --rawfile src "$src" --arg variant "$variant" \
    --argjson ret "$RET" --argjson lt "$LT" --argjson plus "$PLUS" --argjson gt "$GT" '
    def m($id; $mut; $rep; $status; $line; $s; $e):
      {id:$id, mutatorName:$mut, replacement:$rep, status:$status, location:{start:{line:$line, column:$s}, end:{line:$line, column:($e)}}};
    ($variant == "after") as $after |
    {schemaVersion:"2", thresholds:{high:80, low:60}, framework:{name:"Stryker", version:"8.7.1"},
     files:{"src/collision.ts":{language:"typescript", source:$src, mutants:[
       m(if $after then "20" else "0" end; "EqualityOperator"; "<"; (if $after then "Killed" else "Survived" end); $ret; $lt; $lt + 2),
       m(if $after then "21" else "1" end; "EqualityOperator"; ">"; (if $after then "Survived" else "Killed" end); $ret; $lt; $lt + 2),
       m(if $after then "22" else "2" end; "EqualityOperator"; ">="; (if $after then "Survived" else "NoCoverage" end); $ret; $gt; $gt + 1),
       m("3"; "ArithmeticOperator"; "-"; "Timeout"; $ret; $plus; $plus + 1),
       m("4"; "ArithmeticOperator"; "*"; "CompileError"; $ret; $plus; $plus + 1),
       m("5"; "ArithmeticOperator"; "+"; "Survived"; $ret; $plus; $plus + 1),
       m("6"; "StringLiteral"; "\"\""; "Survived"; 2; 3; 4),
       m("7"; "LogicalOperator"; "||"; "Survived"; $ret; $plus; $plus + 1),
       m("8"; "ArrowFunction"; "() => undefined"; "RuntimeError"; $ret; $plus; $plus + 1),
       m("9"; "BooleanLiteral"; "false"; "Pending"; $ret; $plus; $plus + 1)
     ]}}}' > "$WORK/raw-$variant.json"
}
raw_report "$WORK/candidate-source.ts" before
raw_report "$WORK/candidate-source.ts" after

node "$MUTATION" report --stryker="$WORK/raw-before.json" --risk="$WORK/risk.json" --plan="$P" --repo="$REPO" --candidate="$CAND" --equivalent=7 --out="$WORK/before.json" \
  || fail "report command failed"
B="$WORK/before.json"
check "$B" '.schema == "atd.mutation-report/v1" and .tool.name == "stryker" and .tool.version == "8.7.1"' "report identity"
check "$B" ".baseCommit == \"$BASE\" and .candidateCommit == \"$CAND\" and .seed == $(jq .seed "$P") and .configSha256 == \"$(jq -r .configSha256 "$P")\" and .scope == \"hunks\"" "report provenance binds the plan and revisions"
check "$B" '.counts == {"total":10,"killed":2,"survived":2,"equivalent":2,"invalid":2,"ignored":0,"unknown":2,"noCoverage":1,"timeout":1}' "outcome counts follow killed/survived/equivalent/invalid/unknown semantics"
check "$B" '.score == 0.5' "score = killed / (killed + survived), excluding equivalent, invalid and unknown mutants"
check "$B" '(.mutants | map({(.id): .outcome}) | add) == {"0":"survived","1":"killed","2":"survived","3":"killed","4":"invalid","5":"equivalent","6":"unknown","7":"equivalent","8":"invalid","9":"unknown"}' "per-mutant outcomes"
check "$B" '(.mutants | map({(.id): .detail}) | add) | .["5"] == "identical_replacement" and .["7"] == "reviewed" and .["6"] == "out_of_scope" and .["3"] == "timeout" and .["2"] == "no_coverage"' "outcome details explain why"
check "$B" '.gaps | map(.id) == ["0","2"] and all(.kind == "surviving_gap" and .confirmedBug == false and .symbol == "overlaps")' "survivors are test-suite gaps attributed to the changed function, never confirmed bugs"
check "$B" '.gaps | map(.subtype) == ["survived","no_coverage"]' "no-coverage survivors are distinguished"
check "$B" '.gaps[0] | .original == "<=" and .replacement == "<" and .mutator == "EqualityOperator"' "gap records original and replacement"
check "$B" '.semantics.survived | test("GAP") and (. | test("NOT evidence of a product defect"))' "survivor semantics documented in the report"
check "$B" '.semantics.confirmedBug | test("differential")' "only differential evidence can confirm a bug"
check "$B" '(has("confirmedBugs") | not) and ([.gaps[] | .confirmedBug] | any | not)' "mutation never reports confirmed bugs"
check "$B" ".sourcePreserved == true and .sources == [{\"file\":\"src/collision.ts\",\"reportSha256\":\"$SOURCE_SHA\",\"candidateSha256\":\"$SOURCE_SHA\",\"matches\":true}]" "embedded source verified against the candidate revision"
[[ "$(sha256_of "$REPO/src/collision.ts")" == "$SOURCE_SHA" ]] || fail "mutation tooling modified the source tree"
[[ -z "$(g status --porcelain=v1)" ]] || fail "repository left dirty"

# without plan/repository: unavailable values stay null (never fabricated)
node "$MUTATION" report --stryker="$WORK/raw-before.json" --risk="$WORK/risk.json" --out="$WORK/before-lite.json"
check "$WORK/before-lite.json" '.seed == null and .configSha256 == null and .scope == null and .sourcePreserved == null and .sources[0].matches == null' "unavailable provenance is null, not guessed"

# tampered / mismatching embedded source
sed 's/<=/</' "$WORK/candidate-source.ts" > "$WORK/tampered-source.ts"
jq -n --rawfile src "$WORK/tampered-source.ts" --slurpfile raw "$WORK/raw-before.json" '$raw[0] | .files["src/collision.ts"].source = $src' > "$WORK/raw-tampered.json"
if node "$MUTATION" report --stryker="$WORK/raw-tampered.json" --risk="$WORK/risk.json" --plan="$P" --repo="$REPO" --candidate="$CAND" --out="$WORK/tampered.json"; then
  fail "a report over different source must fail"
fi
check "$WORK/tampered.json" '.sourcePreserved == false and .gaps == [] and .score == null and (.mutants | all(.outcome == "unknown")) and ([.mutants[] | select(.detail == "source_mismatch")] | length == 9) and (.warnings | length > 0)' "source mismatch invalidates every in-scope mutant"

# no mutants => score is unavailable, not zero
jq -n --rawfile src "$WORK/candidate-source.ts" '{schemaVersion:"2", files:{"src/collision.ts":{language:"typescript", source:$src, mutants:[]}}}' > "$WORK/raw-empty.json"
node "$MUTATION" report --stryker="$WORK/raw-empty.json" --risk="$WORK/risk.json" --out="$WORK/empty.json"
check "$WORK/empty.json" '.score == null and .counts.total == 0 and .gaps == []' "no mutants: null score"

# mutants in unplanned files are excluded
jq '.files["src/other.ts"] = .files["src/collision.ts"]' "$WORK/raw-before.json" > "$WORK/raw-extra.json"
node "$MUTATION" report --stryker="$WORK/raw-extra.json" --risk="$WORK/risk.json" --plan="$P" --out="$WORK/extra.json"
check "$WORK/extra.json" '[.mutants[] | select(.file == "src/other.ts")] | length > 0 and all(.outcome == "unknown" and .detail == "out_of_scope")' "mutants outside the planned files are out of scope"
check "$WORK/extra.json" '.gaps | map(.file) | unique == ["src/collision.ts"]' "out-of-scope survivors are not gaps"

# malformed reports
for payload in '{}' '{"files":[]}' '[]' 'not json'; do
  printf '%s' "$payload" > "$WORK/raw-bad.json"
  if node "$MUTATION" report --stryker="$WORK/raw-bad.json" --risk="$WORK/risk.json" --out="$WORK/bad.json" 2>/dev/null; then
    fail "malformed Stryker report $payload must be rejected"
  fi
done

# --------------------------------------------------------------------------- 3. before/after comparison
node "$MUTATION" report --stryker="$WORK/raw-after.json" --risk="$WORK/risk.json" --plan="$P" --repo="$REPO" --candidate="$CAND" --equivalent=7 --out="$WORK/after.json"
node "$MUTATION" compare --before="$B" --after="$WORK/after.json" --out="$WORK/cmp.json" || fail "compare failed"
check "$WORK/cmp.json" '.schema == "atd.mutation-comparison/v1"' "comparison schema"
check "$WORK/cmp.json" '.killedNow | length == 1 and .[0].beforeId == "0" and .[0].afterId == "20" and .[0].mutator == "EqualityOperator" and .[0].replacement == "<"' "surviving mutant killed by the added tests, matched by location/mutator/replacement rather than id"
check "$WORK/cmp.json" '.stillSurviving | length == 1 and .[0].id == "22"' "remaining gap"
check "$WORK/cmp.json" '.newlySurvived | length == 1 and .[0].id == "21"' "regression surfaced"
check "$WORK/cmp.json" '.before.score == 0.5 and .after.score == 0.5 and .scoreDelta == 0' "scores reported; an equal score can hide a regression that the per-mutant lists expose"
check "$WORK/cmp.json" '.scoreDelta != null' "score delta reported when both scores exist"
check "$WORK/cmp.json" '.note | test("not evidence of a product defect")' "comparison keeps gap semantics"

node "$MUTATION" report --stryker="$WORK/raw-before.json" --risk="$WORK/risk.json" --plan="$WORK/plan4/mutation-plan.json" --out="$WORK/before-symbols.json"
if node "$MUTATION" compare --before="$B" --after="$WORK/before-symbols.json" 2>"$WORK/err.txt"; then fail "different scopes must not be compared"; fi
grep -q 'provenance_mismatch' "$WORK/err.txt" || fail "scope mismatch not reported"
node "$MUTATION" report --stryker="$WORK/raw-before.json" --risk="$WORK/risk2.json" --out="$WORK/other-diff.json" 2>/dev/null || true
if [[ -s "$WORK/other-diff.json" ]]; then
  if node "$MUTATION" compare --before="$B" --after="$WORK/other-diff.json" 2>/dev/null; then fail "different diffs must not be compared"; fi
fi
if node "$MUTATION" compare --before="$B" --after="$WORK/tampered.json" 2>/dev/null; then fail "a source-mismatched run must not be compared"; fi

# --------------------------------------------------------------------------- 4. invalid invocations
set +e
node "$MUTATION" >/dev/null 2>&1; [[ $? -eq 2 ]] || { echo "FAIL: no command must exit 2" >&2; exit 1; }
node "$MUTATION" config >/dev/null 2>&1; [[ $? -eq 2 ]] || { echo "FAIL: missing flags must exit 2" >&2; exit 1; }
set -e
node "$MUTATION" --help | grep -q 'NEVER runs Stryker' || fail "--help must state that execution is confined"

echo "PASS: mutation — scoped deterministic Stryker config (vitest/node:test), no host execution, report semantics (killed/survived/equivalent/invalid/unknown, gaps never bugs), source preservation, null for unavailable, surviving->killed comparison"
exit 0
