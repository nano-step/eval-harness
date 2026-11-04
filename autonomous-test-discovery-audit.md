# Autonomous Test Discovery — Phase 0 architecture audit and integration contracts

Audit date: 2026-11-03. Scope: Phase 0 of the "Autonomous Test Discovery for eval-harness + QA Factory" plan.
This document is the only artifact of Phase 0. It changes no code.

## Recovery context — 2026-11-03

The original Phase 0 findings below describe the audit-time environment, not the
current implementation state. The coordinator preserved that evidence rather
than re-running the completed architecture audit.

- The original Jev implementation stopped at budget admission. Work now uses a
  stable checkout of `nano-step/eval-harness`, based on `002aafee`, on branch
  `feature/v0.6.0-autonomous-test-discovery`; the img2threejs-bound run is not resumed.
- `jq` 1.8.2 is installed. The unchanged `002aafee` baseline passed all 57
  suites in 402.29 seconds; the historical missing-jq failures below are not
  current test results.
- The approved sandbox image is
  `node@sha256:4b150b48b4116e2a22f2c39cc27025fbf4f153e2078fd3b14d159fdb5c7279da`.
  A live probe observed Node v22.23.4, UID 65534, read-only rootfs and source,
  writable bounded tmpfs, zero effective capabilities, `NoNewPrivs: 1`, and
  denied TCP egress (`ENETUNREACH`). Node 22 supports the maintained pilot tooling.
- QA Factory's existing executable `oracle` command hook will own the discovery
  entrypoint through an adapter shipped in this repository. This supersedes the
  contract-only ownership proposal in sections 7.7–8; no new database or QA
  framework is introduced.
- Jev retains its existing bounded test-command/repair integration; its live
  controller is not rebuilt or changed.
- An exact specification quote establishes provenance, not semantic correctness
  of an assertion. Stable differential failures without trusted expectation
  support remain suspected; a generator cannot approve its own expectation.
- Local signatures remain same-user evidence. Discovery remains warn-only;
  independently controlled signer trust is required before enabling blocking.

Implementation and benchmark results must be recorded only after exercising the
changed paths. These prerequisite measurements are not feature acceptance.

## Verification checkpoint — incomplete, not a release

- The main session ran `discovery_risk.sh`, `discovery_candidates.sh` and
  `discovery_mutation.sh`: all three passed, with a combined elapsed time of
  229.17 seconds. These cover static discovery modules, not the live model pipeline.
- Main-session runtime reproductions caught semantic-diff false negatives for
  `return` ASI and escaped strict directives, and incorrect assertion/runtime-error
  precedence. Fixes and behavioral regression cases were added.
- A sandbox-owner scratch reproduction demonstrated a host write through an
  exported symlink before the fix; afterward the runner exited 13 and the outside
  directory remained empty. A workflow-owner reproduction demonstrated a forged
  manifest executing a host shell check before admission was added; afterward
  the check was refused and its sentinel was absent.
- Storage initially blocked execution. The user freed space; the main session
  measured approximately 12.5 GiB available and resumed without deleting unrelated
  caches.
- The first integrated gate ran for 1,640.60 seconds and failed four suites:
  live Vitest differential execution, cross-run container counting, a baseline
  scan that matched its own fixture, and a macOS `/var` versus `/private/var`
  round-path assertion. The remaining suites passed, including real mutation
  sandbox, QA command-hook, Jev gate and report compatibility suites. Fixes are
  not counted as verified until rerun.
- The first live Sonnet pilot ran for 228.86 seconds: three successful model
  calls produced 19 candidates, but none passed admission. The prompt's common
  JSON example contradicted the strategy-specific validator by including
  `killsMutantIds` on non-mutation candidates. The validator remained strict;
  the corrected strategy-specific prompt admitted candidates in the next run.
- Real Stryker execution measured 15/15 killed mutants in changed-line scope.
  Both inclusive-boundary mutants were killed by the existing symmetry property,
  with a shrunk edge-touch counterexample. This is real coverage, not a coverage
  gap. The next run uses the originally requested changed-function scope;
  baseline tests, property seeds and production fixture source remain unchanged.
- The failed pilot recorded 12 fresh-input tokens, 13,818 output tokens and
  USD 2.0203312 generation cost; cached input is recorded separately in its raw
  report. These are pipeline-only observations, not main-session or
  worker-inclusive usage and not evidence of quota or quality gains.
- At that checkpoint, the successful mutation comparison, independent CI run
  and final benchmark were unverified. Domain expansion remained sequenced
  after a successful pilot; no PR or merge had yet been performed.

- A separate live Stryker budget smoke planned 35 mutants with a cap of 2 and
  refused before mutant execution. It exited 13 in 39.63 seconds, retained
  `budget_exceeded` evidence with null counts/score, and signature/digest
  verification returned `valid` with reporting-only `local-same-user` trust.
- The second live pilot ran for 2,431.30 seconds: three real Sonnet calls
  produced 17 candidates, 15 statically admitted across the three generation
  rounds. Every differential execution
  was inconclusive because the runner conflated its host input directory with
  revision placement (`/work/tests/test/...` instead of `/work/test/...`).
  A second integrated gate was cancelled after this causal failure; it has no
  final acceptance verdict.
- The sandbox owner replayed the same archived candidate bytes before and after
  separating `testsDir` from `testsRel`: the missing-import compile error became
  a genuine PASS→PASS on the clean revision, with valid signed evidence.
  This focused result does not establish pilot acceptance.
- Changed-function mutation measured 35 mutants: 31 killed, four survived,
  zero timeout. Two survivors remove second-rectangle zero-size guards and are
  contract-relevant gaps; two only change diagnostic argument labels not
  promised by the specification. Raw counts remain unchanged.
- Main-session semantic review rejected the generated `invalid-rect-names`
  proposal: distinct error messages are not specified. The archived proposal
  is retained, not rewritten to fit a score. The mutation consumer now honors
  a supplied negative review even for PASS→PASS; its exclusion from an actual
  generated-test mutation execution remains unverified.
- The second failed attempt recorded 12 fresh-input tokens, 13,894 output tokens
  and USD 0.4893628000000001 generation cost. These are not an A/B quality or
  efficiency comparison: the prompts and cached-context state differed.
- The earlier stored pilot report counted only 12 admissions because it merged
  three distinct clean proposals sharing an ID across generation rounds. The
  original failed report remains preserved; proposal identity now includes its
  original generation round. After rejecting the unsupported error-message
  assertion, the frozen CI selection contains 14 proposals.
- The three frozen replays completed in 1,636.99 seconds with zero fresh model
  calls. All ten clean executions passed. Four defect proposals produced
  reviewed, reproducible PASS→FAIL regressions with three fresh signed samples
  each; the corner-only test correctly reported no finding. Their trust remains
  reporting-only `local-same-user`, not authority to block or request repair.
- A real 355.93-second Stryker reproduction accepted an unsigned baseline
  directory containing only edited JSON summaries and falsely reported one
  survivor-to-killed transition. The original mutant had already been killed.
  The mutation command now verifies signed raw evidence before consuming it.
  Main repeated the exact unsigned-baseline attack: exit 13 in 0.56 seconds,
  before Docker execution, with no measurement output directory created.
  The subsequent signed generated-test overlay completed in 523.48 seconds.
  Four reviewed tests were overlaid; the unsupported error-message test was
  excluded by its hash-bound FAIL review.
  The pilot report now re-verifies signed raw reports and the selected tests
  tree instead of trusting derived sidecar scores. A live report against the
  forged directory returned an unavailable comparison and a null gap
  acceptance; the genuine signed baseline retained its measured counts.
  Timeout is no longer counted as an assertion-killed gap; a focused behavior
  check distinguished Timeout from Killed. A fresh signed baseline completed in
  402.50 seconds under the current runner. A real signed overlay changed
  mutants 28 and 30 (second-rectangle zero width/height guards) from Survived
  to Killed; raw counts changed from 31/35 to 33/35, score 88.57 to 94.29.
  Two remaining string-label mutants are not specification-backed gaps.
  A separate report recomputed all seven pilot acceptance checks as met;
  the signer is still local reporting-only, not independent CI authority.
- An additional unchanged-suite control completed in 33.17 seconds. The same
  existing test bytes (`a359d411ba187d6eef5e8ca514aa42dd0d3c0cbb4fd2ef68fd1610509cdb6e65`)
  passed 12/12 on both the base and isolated boundary-defect revisions.
  Signature/digest verification returned valid, environment-equal PASS→PASS
  with reporting-only local trust. This demonstrates that the existing suite
  missed the injected defect; it is not another generated proposal.
- Sonnet returned HTTP 429 `rate_limit_error`, with `retry-after-ms=7546000`.
  The user subsequently explicitly authorized GPT 6.1 for implementation;
  work resumed using that model, without M3 fallback.
  At that checkpoint, final integrated acceptance, publication and merge were
  incomplete; no PR had yet been opened.
- A real GPT 6.1 QA generation made one call (150,424 input, 1,229 output,
  reported cost USD 0), then hit `ENOSPC` during sandbox execution. Its
  partial artifacts are retained; the QA operation did not complete.
- After the user freed disk space, the QA security/protocol suite passed in
  245.73 seconds, including the real `qa_factory.hooks.command_hook` consumer
  over independently signed fixture evidence. This is not the interrupted
  live GPT operation.
- Docker Desktop's daemon socket later refused connections despite its UI
  reporting running. The user authorized a restart; the daemon recovered.
  A subsequent domain acceptance attempt was interrupted by a separate
  containerd outage (`unexpected EOF`) and was rerun after recovery.
- The completed real GPT QA retry took 605.44 seconds and returned three
  reproducible suspected regressions through the actual QA Factory hook. It
  correctly remained `INCONCLUSIVE`, with no independent-review promotion.
  Its one generation call reported 145,944 input tokens, 1,625 output tokens,
  zero cached input and USD 0 cost. Main/worker-inclusive usage is unavailable;
  the earlier interrupted call is recorded separately above.
- The optional img2threejs evaluator was exercised with the pinned Playwright
  image in Docker (Node v24.11.1, Linux ARM64). A valid fixture passed the
  geometry, scene graph, materials, animation and runtime dimensions; without
  approval, visual was `UNAVAILABLE`. The actual screenshot was visually
  inspected by the Terra main session and an external hash-bound baseline
  recorded. The subsequent 234.35-second acceptance run passed real
  compile, load, WebGL, render, GLB export and visual negative scenarios,
  verified screenshot tampering and baseline immutability, and left each
  dimension independent. The first fixture exposed two real issues: material
  groups are ignored by Three.js for a single material, and scalar Euler
  animation did not survive glTF export; both were corrected before the
  passing run.
- `npm pack --dry-run` included the optional integration and audit, with no
  node_modules, private-key or cache paths in its 292-file manifest.
- A full compatibility run with live Vitest and domain inputs completed in
  2,647.03 seconds: 75 suites passed and `discovery_repair_cap` failed because
  the macOS entrypoint fix attempted `realpath("-")` during a stdin-module
  import. The entrypoint now handles non-file invocation; the targeted repair
  cap test passed in 3.79 seconds, and the real QA command-hook suite passed
  after the same fix. The complete post-fix gate passed all 76 suites in
  2,477.89 seconds, with live Vitest and the approved domain browser inputs.
  The failed earlier run remains recorded above.
- The first PR CI run exposed three platform-specific failures missed locally:
  jq 1.6 rejected an unparenthesized manifest expression; the Python timeout
  fallback consumed the child process's piped input; and a sourced test helper
  overwrote the Jev test's directory variable. CI evidence could not complete
  and was not promoted. The manifest fix passed a real Linux jq 1.6 grading
  test; the timeout fallback now has a piped-input regression.
- The corrected [independent CI run](https://github.com/nano-step/eval-harness/actions/runs/41824511878)
  passed on the PR merge commit for head `cd9d8232311e6a6821f4b95a73655007c985be8b`.
  Its ephemeral public signer fingerprint matched the authenticated job log;
  downloaded mutation and differential signatures were independently verified.
  All eight collision behaviors were covered, clean runs stayed unflagged,
  four independently signed regressions reproduced, and block mode emitted
  one bounded repair request. The two zero-size guard mutants changed from
  Survived to Killed (31/35 to 33/35); frozen replay made zero model calls.
  Linux and macOS shell CI also passed. The run's fixture and signer are
  isolated CI evidence, not proof of production signer separation.


## 0. Decision summary

1. **eval-harness is real, but it is not TypeScript.** The evaluation authority is
   `nano-step/eval-harness` v0.5.0 (`002aafee3ed60ab6cde5acda8cdb49f70e2ca2c5`): a Bash + `jq` + `yq` +
   Python-stdlib CLI. It has no `src/`, no `index.ts`, no build step and no programmatic JS API. The
   provisional paths in the Jev plan (`eval-harness/src/index.ts`, `src/discovery-runner/`, …) do not
   exist and must not be created. New discovery code follows the repository's conventions: Bash
   libraries under `scripts/eval/lib/`, a runner adapter under `scripts/eval/runners/`, Bash test
   suites under `scripts/eval/tests/`, and dependency-free Node ESM (`.mjs`, Node ≥18 per
   `package.json` `engines`) only where structured parsing is needed.
2. **Reuse, do not rebuild.** eval-harness already implements typed statuses, baseline comparison,
   A/B base-vs-candidate classification, stability sampling, drift attribution, content-addressed
   grading manifests, JUnit/SARIF, warn-only/strict gates, cost/token/latency tracking, history and a
   harness false-positive meta-evaluation. Discovery plugs in as **one new runner adapter** and **one
   new check kind** (both additive under `POLICY.md`). No new database, report format, status
   vocabulary or orchestration framework is needed.
3. **A fail-closed isolation boundary exists on this host but is not yet operational.** Docker
   20.10.16 (linux/arm64) enforced no-network, read-only rootfs, zero capabilities,
   `no-new-privileges`, non-root UID, pids/memory/CPU limits and read-only source mounts in live probes
   (§6.3). `--pull never` fails closed when the pinned image is missing. No Node image is present
   locally, so untrusted tests cannot run until a digest-pinned image is approved and pulled (B-3).
4. **Stop condition triggered for cross-repository implementation in this Jev run.** This Jev run
   is bound to the img2threejs repository, and Jev's `Workspace` handles one repository per run
   (`jev-orchestrator/src/workspace.ts:48-58`). eval-harness has no checkout under Jev control, the host
   lacks `jq` (47 of 57 eval-harness suites fail locally), QA Factory is not under version control, and
   the Jev repository has no commits or remote. Implementation tasks that own eval-harness, QA Factory
   or Jev paths must not start in this run. They need the prerequisites in §9. No img2threejs-owned
   implementation is required before the pilot.

## 1. Method and evidence rules

- A capability is **IMPLEMENTED** only when executable code on the inspected commit performs it. It
  is **PARTIAL** when code exists but misses a requirement of this plan. It is **PLANNED** when only
  design or schema text exists. It is **MISSING** when there is no code or design. Documentation alone
  never counts as implementation.
- Paths are repository-relative and include line ranges where they were read. eval-harness paths
  refer to the audit clone `/tmp/atd-audit/eval-harness` at `002aafee`. That clone is temporary
  read-only evidence, not a working checkout.
- Every command result in §11 was observed in this session. Claims I did not observe are marked
  `[INFERENCE]`.

## 2. Repository inventory

| ID | Component | Location / remote | Commit | VCS state | Language / test entrypoint | Observed here |
|---|---|---|---|---|---|---|
| R-EH | eval-harness | `github.com/nano-step/eval-harness` (public; `gh` reports push/admin). No local checkout; read-only audit clone in `/tmp/atd-audit/eval-harness` | `002aafee3ed6…` (main, v0.5.0) | Git, clean | Bash/jq/yq/Python stdlib; `npm test` → `bash scripts/eval/test.sh` (57 suites) | 10 PASS / 47 FAIL on this host. The failures are `jq: command not found`; the host has no `jq` binary (§11) |
| R-EH′ | older eval-harness mirror | `github.com/workspace-backup-nhonh/eval-harness` (private) | `0f36aef7…` | Git, last push 2026-09-25 | — | Superseded by R-EH, which has newer pushes and the merged PR #45. Do not target it |
| R-QAF | QA Factory | `/Users/hoainho/Document/Personal/qa-agents-factory` | — | **Not a git repository** (`git log` → fatal) | Python 3.12, `uv`, pytest | `tests/test_models.py`: 14 passed |
| R-JEV | Jev orchestrator | `/Users/hoainho/Document/Personal/jev-orchestrator`; `~/.local/bin/jev` → `dist/src/cli.js` | — | Git repository with **no commits and no remote**; every file untracked | TypeScript 5.9, Node ≥20; `npm test` builds into `dist/` | `tsc --noEmit` exit 0. `npm test` was **not** run because it rewrites the live controller in `dist/` |
| R-PJ | plugin-jev | `/Users/hoainho/Document/Personal/plugin-jev` → `img2threejs/plugin-jev` | `f4ae0693…` | Git | img2 plugin (advisory routing) | Not used by the run controller |
| R-PIXI | img2pixi2d plugin | `/Users/hoainho/Document/Personal/img2-plugins/pixi2d` → `img2threejs/pixi2d` (push/admin) | `008d8c7d…` | Git | Python `skills/img2pixi2d/forge/*.py`, Node CLI `cli/test/safety.test.mjs` | No collision function and no TypeScript tests (§4.6) |
| R-I2T | img2threejs (this worktree) | `img2threejs/img2threejs` | `d508b596…` | Git (Jev worktree) | Python `forge/`, `npm test` → `node --test bin/img2threejs.mjs-test.mjs` | Jev baseline: `npm test` passed on the base |
| — | nano-brain-go eval schema | `nano-brain-go/scripts/schema/007-eval-harness.sql` | `49e058f` | Git | SQL only | No Go code references `eval_run`/`eval_case`, and eval-harness has no SQLite writer. This is an orphaned schema (**PLANNED**), not an evidence store |

## 3. Mandatory references and design implications

| Ref | What was read | Implication adopted |
|---|---|---|
| R1 Meta Catching JiTTests (2026-10-29) | Two workflows: intent-aware (infer intent → risks → mutants → tests that kill them) and dodgy-diff (treat the diff as a mutant). Weak catch = generated test that fails on the diff; strong catch = true positive. False positives are filtered by the deterministic RubFake rules plus an LLM-as-Judge ensemble. Human-on-the-loop: humans set criteria and review in aggregate. Reported true-positive rate is 60%. Targeting uses a diff-risk score. | A failing generated test is a *weak catch*. It becomes `VERIFIED_REGRESSION` only through deterministic, reproducible, specification-supported evidence (§7.5). The LLM judge is supporting evidence and cannot gate (§7.6). A 60% true-positive rate at Meta means false positives are routine, so discovery starts in **warn-only** mode. Risk targeting comes first, with deterministic rules before any LLM. |
| R2 Stryker mutant states | States: Pending, Killed, Survived, NoCoverage, Timeout (counts as detected), RuntimeError and CompileError (both invalid and excluded from the score), Ignored. Score = detected/valid. A covered-code score is also defined. | Mutation reports use Stryker's states and formulas unchanged. A survived mutant is recorded as test-gap evidence (non-blocking), never as a defect. Equivalent mutants are recorded as `Ignored` with a reason. Mutation score is an optional, non-gating `metric_score`. |
| R3 fast-check | Seeded RNG gives repeatable generation. Default is 100 runs per property. Counterexamples are shrunk. Works inside any test runner. | Property-based candidates must record `seed` and run count in the execution record. The runner injects a fixed seed, and reruns reuse it. A shrunk counterexample is captured as an artifact. |
| R4 Vitest reporters | `json`/`junit` reporters write files (`outputFile`). `stdout` reports can interleave and become unparsable. The default reporter set changes when an AI agent is detected. | The runner pins `--reporter=json --reporter=junit` with explicit `outputFile` paths and never parses terminal output. Outcome is derived from the JSON report (§7.3). |
| R5 Playwright visual comparisons | Rendering varies with OS, browser, hardware and headless mode. Baselines are per browser and platform. `--update-snapshots` rewrites baselines. `threshold`/`maxDiffPixels` tolerances. | Visual checks run only in the pinned image and platform. Discovery runs must reject `--update-snapshots` and must never write baselines. Visual similarity is never the only criterion; img2threejs structural gates stay authoritative (§4.6). |
| R6 Promptfoo CI/CD | JSON/JUnit outputs, quality gates via exit code or JSON thresholds, CI tags carrying the git SHA. | eval-harness already provides `--report=junit\|sarif`, `--trigger`, typed exit codes, `--max-regressions`, `--strict`, `promote` and a composite GitHub Action. Promptfoo is **not** added. |

## 4. Capability classification (code evidence)

### 4.1 eval-harness (`nano-step/eval-harness@002aafee`)

| Capability | Status | Code evidence | Reuse decision |
|---|---|---|---|
| CLI entrypoint and subcommands | IMPLEMENTED | `package.json` `bin.eval-harness` → `scripts/eval/run.sh`. Dispatch in `run.sh:45-50` covers `baseline\|status\|promote\|trend\|accept\|apply\|ab\|rebaseline\|metaeval\|calibrate\|grade`. Usage and exit codes in `run.sh:51-99` | The public surface is the CLI plus its on-disk files. Discovery adds no new CLI subcommand in v1 |
| Programmatic / TypeScript API | MISSING | No JS/TS sources in the repository | Do not add one. Consumers read `results.json` (schema 3) |
| Case runner loop | IMPLEMENTED | `run.sh:375-758`. Per-case dir `$STATE_DIR/runs/$RUN_ID/$cid` (`run.sh:321-324,451-456`), workdir-confined fixtures (`run.sh:459-514`), locks (`run.sh:519-546`) | Discovery cases run through this loop unchanged |
| Runner adapters | PARTIAL | Contract (prepare/spawn/fingerprint/teardown) in `docs/runners.md:21-32` and `lib/runner.sh:112-142`. The custom-runner spawn shape exists (`run.sh:186-187`), but `run.sh:424-436` rejects any runner other than `opencode`/`langgraph-node` with ERROR | Add `atd-sandbox` with an additive branch in `run.sh:424-436` |
| Graders | IMPLEMENTED | `lib/score.sh:44-73`: `shell` (constrained, `safe_shell.py`), `jq_path_contains`, `file_exists`, `output_contains`, `output_not_contains`, `llm_judge`, `metric_score`, `trajectory`, `human_review` (`lib/extended_graders.sh`) | Add one kind, `discovery_finding` (§7.5). `POLICY.md` classifies new check kinds as MINOR/additive |
| Typed status vocabulary | IMPLEMENTED | Check status → case status in `lib/score.sh:449-456`: required ERROR > FAIL > PENDING→NEEDS_REVIEW > UNAVAILABLE/ABSTAIN→INDETERMINATE > PASS. Optional checks report but do not gate. Run verdict precedence in `lib/diff.sh:104-110`: ERROR > REGRESSION > FAIL > NEEDS_REVIEW > INDETERMINATE > PASS | Preserved as-is. All discovery classes map onto it (§7.5) |
| Stored-baseline comparison | IMPLEMENTED | `lib/diff.sh:14-84`; `regression` = `compare_to_baseline ∧ baseline_passed ∧ status==FAIL` (`diff.sh:75`); single-writer `baseline.sh` (refuses overwrite without `--force`); `accept.sh` (only a PASS run); `rebaseline.sh` (refuses PASS→FAIL) | Discovery **never** writes baselines and never emits `REGRESSION` (that word stays reserved for stored-baseline PASS→FAIL) |
| Baseline tamper detection | PARTIAL | `lib/stability.sh:17-34` checksum. On mismatch `diff.sh:28-30` only **warns** and continues | Out of scope to change. Discovery evidence uses signatures (§7.4) and does not rely on this |
| Base vs candidate A/B | IMPLEMENTED (skill-scoped) | `ab.sh:221-240` classifies per case: ERROR, NEEDS_REVIEW, INDETERMINATE, PASS→FAIL=REGRESSION, FAIL→PASS=improved, candidate FAIL. Exits `ab.sh:311-313` (12/14) | The classification table is reused **semantically** in the runner's differential (§7.3). `ab.sh` itself is not used: it compares two *skills*, has no warn-only mode (always exits 12) and would need synthetic skill pairs |
| Stability sampling | PARTIAL | `run.sh:694-740` re-spawns on a non-PASS primary when `--stability-samples>1`; `hash_checks` covers `{kind,passed,failed_check_id}` (`stability.sh:11-14`); flakiness → `NON_DETERMINISTIC_DRIFT` (`diff.sh:53-57`). **Gap:** the resample `case` (`run.sh:706-720`) only re-spawns `opencode`/`langgraph-node`. For any other runner the sample re-grades a *copy of the already-written workdir* (`run.sh:704`), so the result looks reproducible without re-executing | The only reproducibility mechanism. It must gain a generic `_spawn_case_runner` branch, and the runner must clear prior outputs (§7.3) |
| Drift attribution | IMPLEMENTED | `lib/attribute.sh:5-53`; explicitly co-occurrence, not causal | Reused unchanged |
| Environment provenance | IMPLEMENTED | `lib/manifest.sh:68-177` env-manifest schema 4 (opencode/node/platform/model/skill/fixture/prompt/rubric/runner/config hashes) | Runner config SHA carries the revision and image digest into attribution |
| Evidence binding | IMPLEMENTED | `lib/grading_manifest.sh:6-50` schema-1 manifest with SHA-256 over case, workdir tree, transcript, artifacts and env. `grade.sh:79-86` rejects digest mismatch (exit 13) | Discovery artifacts are listed in the manifest (§7.4) |
| Evidence authentication | MISSING | `KNOWN_ISSUES.md` "Evidence authenticity": hashes do not establish who produced artifacts, and there are no signatures | Added by detached signatures (§7.4). Host tool verified (§11) |
| Artifact storage | PARTIAL | Per-run directories under `${EVAL_STATE_DIR:-~/.config/opencode/eval-harness}/runs/`, `results.json`, `diff.md` (`run.sh:765-773`). No retention policy or remote store (`KNOWN_ISSUES.md`) | Reused. Evidence URIs are run-dir relative paths plus SHA-256 |
| JUnit / SARIF | IMPLEMENTED | `lib/report_junit.sh:10-39` (failure iff `passed==false`, type = attribution class); `lib/report_sarif.sh:8-38`; wired through `--report=fmt:path` (`run.sh:774-787`) | Unchanged. Note: NEEDS_REVIEW and INDETERMINATE cases already render as JUnit failures because `passed:false`. This is existing behavior, kept for compatibility |
| Quality gates | IMPLEMENTED | Warn-only by default; `--strict` exits 14/15/16; `--max-regressions` exits 12; `promote.sh` (7-day history, no bypass); `EVAL_BYPASS` logged; ERROR always exits 13 (`run.sh:798-837`) | The discovery gate maps onto these exits (§7.5, §7.7) |
| Cost / token / latency | IMPLEMENTED | `diff.sh:112-138` measured/partial/unavailable; `budget.sh` daily cap; per-case `duration_ms` (`run.sh:750-753`) | Reused for the §16 cost metrics |
| History / trend | IMPLEMENTED | Append-only `history.ndjson` (`run.sh:202-222,788`), `trend.sh`, `status.sh` | Every repair round is a distinct run id and history line |
| LLM judge | PARTIAL | `lib/llm_judge.sh`: Anthropic Messages API only (`:6-7,42-51`), PASS/FAIL majority with per-sample raw text and counts (`:76-126`). No explicit uncertainty field | Stage B review = an **optional** (`required: false`) `llm_judge` check. Optional checks cannot gate (`score.sh:449-456`). Agreement counts serve as the uncertainty measure |
| Harness false-positive meta-eval | IMPLEMENTED | `metaeval.sh` (stub-only corpus of known regressions and benign edits → FP/FN rates; refuses real `opencode`) | The pilot's clean-change and injected-defect corpus reports FP/FN in the same, separate artifact style |
| Process sandbox | PARTIAL / unsuitable for untrusted code | `lib/spawn.sh:42-83`: ephemeral HOME/config per case plus a timeout. It **copies `auth.json` credentials into the sandbox** (`:44-54`). No network, filesystem or process isolation. `SECURITY.md`: "is not an OS sandbox" | Not used for generated tests. Replaced by `atd-sandbox` (§6) |
| Mutation / property / diff-risk / test generation | MISSING | No code | New (§8) |
| SQLite / service API / plugin execution / reviewer UI | PLANNED (deferred) | `docs/EVAL_HARNESS_V2.md:172` "Deferred" list | Not introduced |

### 4.2 QA Factory (`qa-agents-factory`, unversioned)

| Capability | Status | Code evidence | Reuse decision |
|---|---|---|---|
| Campaign controller / supervisor | IMPLEMENTED (web-DOM) | `src/qa_factory/supervisor.py:102+`; worker process `:28-87` (`setsid`, `os.environ.clear()`, lease RPC) | Not a code-diff runner. Do not route untrusted unit tests here |
| Worker profiles / personas | IMPLEMENTED | `models.py:79-124` (`Profile`, `Traits`, `PersonaCore`), `profiles.py`, Hermes bridge `hermes_bridge.py` | Not needed for discovery |
| Finding classification and reproduction | IMPLEMENTED (web scenarios) | `models.py:73-77` CONFIRMED_DEFECT / SUSPECTED_DEFECT / SIMULATED_UX. Submissions are always downgraded to SUSPECTED (`findings.py:32-35`). CONFIRMED requires a frozen-oracle-backed failure **and ≥2 independent fresh-namespace reproductions** (`findings.py:79-124`). Human disposition never changes the automatic classification (`findings.py:126-136`) | Reuse the **semantics**: VERIFIED needs ≥3 fresh-container samples (stricter), and dispositions are recorded separately. The `Finding` model requires campaign/session/scenario identities, so it cannot hold code-test findings without schema changes |
| Reports | IMPLEMENTED | `reports.py:41-44` json/html/junit | QA Factory is not the reporting authority for discovery. eval-harness is |
| Network / hook isolation | PARTIAL | `network.py` loopback egress proxy (browser origins); `hooks.py` requires an absolute allowlisted executable and scoped env; README says tool limits are "not an OS sandbox" | Not reused for code execution |
| Code-diff test discovery / generation | MISSING | No diff, AST or test-framework code | §8 places generation in eval-harness and Jev. See §8.1 for the ownership change |
| Version control / PR path | MISSING | Not a git repository | Blocker B-5 |

### 4.3 Jev orchestrator (`jev-orchestrator`, git without commits) and OhMyPi runtime

| Capability | Status | Code evidence | Reuse decision |
|---|---|---|---|
| Task routing / delegation | IMPLEMENTED | `src/router.ts`, `src/types.ts:104-166` (`TaskSpec.files` ownership, `Assignment`, `AttemptRecord`), OMP runtime `src/runtime/omp.ts`, `ModelRuntime.runAgent` (`src/runtime/types.ts:137-142`) | The generation LLM step is a Jev-delegated OMP worker. eval-harness never calls a model to generate tests |
| Base-commit test baseline | IMPLEMENTED | `orchestrator.ts:886-917` runs mandatory tests on the unmodified base in a temporary worktree; `TestResult.baseline` (`types.ts:189-197`); `baselineOf` (`orchestrator.ts:874-878`) | The discovery gate runs as a Jev test command, so Jev's own base/integration comparison also applies |
| Bounded repair | IMPLEMENTED | `policy.ts:152-155` caps `findings.fix` at `budget.maxRepairRounds`; `config/jev.policy.json:93` = 3; repair prompt `agents.ts:194-205`; `testRounds` append-only | Reused unchanged for VERIFIED regressions |
| Independent finding closure | IMPLEMENTED | `types.ts:170-187`: `fixClaim` never closes a finding; only an independent re-review `resolution` does | Matches "implementer cannot mark its own output verified" |
| Typed judge | IMPLEMENTED | `JudgeSpec`/`JudgeResult` (`runtime/types.ts:95-134`, TypeSafe System One) | Not used for Stage B. The plan prefers eval-harness judges, and Jev judgments drive routing, not evidence |
| Test execution isolation | MISSING | `workspace.ts:303-330` `runCommand` = `spawn("sh", ["-c", cmd], {env: {...process.env, CI:"1"}})`, which passes the full host environment, network and filesystem | Jev must only invoke the eval-harness gate. Untrusted tests run inside `atd-sandbox`, never through `runCommand` directly |
| Multi-repository runs | MISSING | `Workspace` binds one repository (`workspace.ts:48-58`); `target.ts` selects one repository or folder | Blocker B-1 for this run |
| Version control / PR path | MISSING | No commits or remote; `dist/` is the live `jev` binary | Blocker B-6 |

### 4.4 Sandbox and test-execution mechanisms on this host

| Mechanism | Status | Evidence |
|---|---|---|
| Docker Engine 20.10.16 linux/arm64 | Available, verified | Probes in §11: network blocked, rootfs read-only, uid 65534, `CapEff 0`, `NoNewPrivs 1`, `:ro` source mount unwritable, tmpfs writable, `/root` unreadable |
| `--pull never` fail-closed | Verified | Missing `node:20-bookworm-slim` → `No such image`, non-zero exit, nothing executed |
| Pinned Node test image | MISSING | Only `pgvector/pgvector:pg16` is local (B-3) |
| `sandbox-exec` (macOS) | Present, not selected | Deprecated profile language and no resource limits. Docker is the boring, portable choice and matches eval-harness's Ubuntu/macOS CI |
| `ssh-keygen -Y sign/verify` (OpenSSH 9.6p1) | Available, verified | A valid signature verifies and tampered content fails (§11). No new dependency |
| `jq` | MISSING on host | The shell builtin is not visible to child processes. `bash -c 'command -v jq'` → none. This breaks eval-harness (B-2) |
| `yq`, `gtimeout`, `python3` 3.12, Node v20.18.1 | Present | `command -v` |

### 4.5 Test tooling for generated tests

| Tool | Status | Evidence |
|---|---|---|
| Vitest / Jest | MISSING in all target repositories | No `node_modules/vitest` in R-JEV, R-PIXI, R-I2T or R-EH. The registry reports `vitest@5.1.0` |
| fast-check | MISSING | Registry `fast-check@4.10.2` |
| StrykerJS | MISSING | Registry `@stryker-mutator/core@10.1.1` |
| Playwright | PARTIAL | Python Playwright used by `img2threejs/scripts/capture_threejs_playwright.py` and QA Factory (`pyproject.toml`). No `@playwright/test` screenshot baselines |

### 4.6 Pilot and domain targets

| Capability | Status | Evidence |
|---|---|---|
| img2pixi2d collision function | MISSING | No `collid|collision|intersect|overlap|aabb` source in `img2-plugins/pixi2d` (Python forge plus a Node CLI only). There are no existing collision tests to "establish baseline" |
| img2threejs geometry checks | PARTIAL | `forge/stage4_review/geometry_integrity.py` (finite checks via `isfinite`, bounds, normals, triangle budgets, LOD validity); `self_intersection.py`, `pairwise_penetration.py` |
| img2threejs runtime / visual capture | PARTIAL | `scripts/capture_threejs_playwright.py` fails closed without a runtime contract; `forge/stage4_review/render_bridge.py`, `diagnose_render.py`, `validate_render_profile.py` |
| img2threejs material / animation checks | PARTIAL | `forge/stage4_review/material_gate.py`; `forge/stage5_rig/rig_gates.py`, `validate_rig_payload.py`, `clip_features.py`. Scene-graph reference and duplicate checks were not found as a dedicated gate |

## 5. Gap analysis: what is reused and what is new

| Plan component | Existing interface reused | New code (justification) |
|---|---|---|
| Diff Analyzer + Risk Classifier | Jev `Classification` is intent-level only (`types.ts:94-102`), so it is not reusable for hunks | `scripts/eval/discovery/risk.mjs`: deterministic rules over a unified diff. Nothing in any repository parses diffs |
| Intent-aware generator | Jev delegation → OMP worker (model selected by Jev); eval-harness case YAML as the test-case carrier | `candidates.mjs` builds bounded generation requests and validates returned candidates. It never calls a model |
| Mutation-guided generator | Stryker (external, maintained); `metric_score` for an optional mutation score | `mutation.mjs` turns changed ranges into a scoped Stryker config and normalizes the report. No custom mutation engine |
| Independent runner | Runner-adapter contract (`docs/runners.md`), `run.sh` loop, `run_with_timeout` | `atd-sandbox` runner plus a Docker profile. The existing spawn copies credentials and has no OS isolation (§4.1), and Jev `runCommand` passes the full host environment (§4.3) |
| Differential evidence | `ab.sh` classification semantics; grading manifest | Differential computed inside one runner spawn (base and candidate under the same image and dependency snapshot) |
| Reproducibility | `--stability-samples` (`run.sh:694-740`) | Additive generic resample branch. No new retry loop |
| False-positive filter A | Typed check statuses | Deterministic rules inside the `discovery_finding` grader |
| False-positive filter B | `llm_judge` (optional) | None |
| Evidence and provenance | Grading manifest schema 1, env manifest schema 4, run dirs | Detached signature (`atd.attestation/v1`), because hashes alone are unauthenticated per `KNOWN_ISSUES.md` |
| Reports and gates | `results.json` schema 3, JUnit/SARIF, warn-only/strict, `promote` | None |
| QA Factory / Jev hook | Jev test-command gate, `maxRepairRounds`, append-only `testRounds` | `jev-gate.sh` exit mapping and a repair-request record. No Jev code change in v1 |
| Metrics | `summary.resources`, `metaeval.sh` pattern, history | A discovery report artifact (counts only, referenced from the manifest) |

No new persistence: everything lives in eval-harness run directories and `history.ndjson`.

## 6. Safe execution prerequisites and the fail-closed sandbox profile

### 6.1 Trust boundaries

- **Untrusted:** generated test source, generated fixtures, candidate source code, model output, the
  requirement quotes a model proposes, and anything inside a container.
- **Trusted (controller-owned, never mounted writable and never in a worker-owned path):** eval-harness
  scripts, the `atd-sandbox` policy file, the signing key, the allowed-signers file, baselines, graders,
  the Jev policy, and the pinned image digest.
- Test-generation agents (OMP workers) may write only candidate test files and a candidate manifest
  in their own worktree. They may not edit eval-harness `scripts/eval/lib/`, `scripts/eval/runners/`,
  the policy, `skills/*/evals/baselines/`, `history.ndjson` or Jev `config/`. This is enforced by Jev
  `TaskSpec.files` ownership and the controller re-running everything itself.

### 6.2 Profile `atd-sandbox/v1` (exact argv; every flag except seccomp was verified in §11)

```text
docker run --rm --pull never --network none --read-only \
  --cap-drop ALL --security-opt no-new-privileges \
  --pids-limit 256 --memory 1g --memory-swap 1g --cpus 2 \
  --user 65534:65534 --workdir /work \
  --tmpfs /tmp:rw,size=64m --tmpfs /work:rw,size=256m,uid=65534 \
  -v <export-of-revision>:/src:ro -v <deps-snapshot>:/deps:ro -v <candidate-tests>:/tests:ro \
  -v <out-dir>:/out:rw \
  --env-file <allowlisted-env> \
  <image>@sha256:<pinned-digest> <argv…>
```

Rules:

1. **Preflight (each failure → runner preflight failure → case `ERROR`, exit 13; never a host
   fallback).** The Docker CLI and daemon must respond. The image digest must be present
   (`docker image inspect`). A probe container must show `getent hosts` failing, `touch /x` failing,
   `id -u` ≠ 0, `CapEff` = 0 and `NoNewPrivs` = 1, and `env` must equal the allowlist exactly. The
   existing convention for missing runner prerequisites is `ERROR` (`run.sh:426-430`). Discovery
   keeps it.
2. **Source export, not worktrees:** `git archive <sha> | tar -x` into a controller temp dir per
   revision. The tree SHA is recorded. No `.git`, hooks or credentials are mounted.
3. **Same dependencies for both sides:** one dependency snapshot per lockfile SHA-256. It is built in a
   trusted setup container (network on, `npm ci --ignore-scripts`) and mounted read-only into both
   sides. If base and candidate lockfiles differ, the comparison is marked `incompatible-environment`,
   which forces `INCONCLUSIVE`. Generated tests cannot install packages: no network, read-only
   `/deps`, and an unknown import becomes a compile error, which Stage A rejects.
4. **Environment allowlist only:** `CI=1`, `TZ=UTC`, `LANG=C.UTF-8`, `NODE_ENV=test`,
   `ATD_SEED=<n>`, `FC_SEED=<n>`. No HOME mount, no `~/.npmrc`, no SSH agent socket, no Docker socket,
   no API keys. This contrasts with `lib/spawn.sh:44-54` and Jev `workspace.ts:307`.
5. **Time:** a host-side deadline via the existing `run_with_timeout`, then `docker kill`. A timeout is
   `error` with `errorClass: "timeout"`.
6. **Cleanup:** `--rm`, tmpfs, and a host trap removes the exports. `/out` is copied into the
   eval-harness case workdir, then hashed.
7. **Visual (Phase 10 only):** a separate pinned image with a browser, the same flags, fixed viewport
   and DPR, `--update-snapshots` forbidden, and baselines mounted read-only.
8. **Privileged repository tests** (anything needing network or credentials) are out of scope for
   v1. They require a separately allowlisted, operator-approved profile and are never granted by
   model output.

### 6.3 Residual isolation risks

- Docker's default seccomp profile is assumed `[INFERENCE: not separately probed]`.
- Docker Desktop shares host paths. Only explicit `-v` mounts are visible, as verified with the
  `:ro` probe.
- The container kernel is shared with other containers on the same VM. This is acceptable for test
  code and is not a VM-grade boundary.

## 7. Versioned cross-component contracts

All records are canonical JSON (keys sorted, UTF-8, no NaN), carry `schema: "atd.<name>/v<N>"`, and
follow eval-harness `POLICY.md` rules. Readers ignore unknown additive fields. Removing or renaming a
field, or changing its meaning, requires `v<N+1>`. Schemas live at
`scripts/eval/discovery/schemas/atd.<name>.v1.json` in eval-harness.

### 7.1 `atd.change-risk/v1` (producer: `risk.mjs`; consumers: generator, mutation)

```ts
interface ChangeRiskReport {
  schema: "atd.change-risk/v1";
  baseCommit: string; candidateCommit: string;     // full 40-hex SHAs
  diffSha256: string; specSha256: string | null;   // task specification bytes
  ruleset: { id: string; sha256: string };          // deterministic rules first
  llmAssist: { used: boolean; modelId?: string; outputSha256?: string }; // advisory only
  targets: ChangeRisk[];
  skipped: { file: string; reason: "generated" | "dependency_dir" | "lockfile" | "formatting_only" | "non_source" | "deleted" | "binary" }[];
}
interface ChangeRisk {                              // plan §5 shape, extended
  file: string; symbols: string[]; riskLevel: "low" | "medium" | "high";
  changedBehaviors: string[];
  suspectedFailureModes: string[];                  // HYPOTHESES — never findings
  affectedTests: string[]; confidence?: number;
  hunks: { startLine: number; endLine: number }[];  // candidate-side ranges; mutation scope
  ruleIds: string[];                                // e.g. "conditional", "boundary", "async", "error_path", "state", "authz", "validation", "math_spatial", "api_contract"
}
```

Invariants: formatting-only hunks (whitespace or comment changes with no AST token change) produce no
target. Files under `node_modules/`, `dist/`, `build/`, `vendor/`, lockfiles and files with generated
headers are skipped. The skip reason is always recorded, never silently dropped.

### 7.2 `atd.test-candidate/v1` (producer: OMP worker via Jev; validator: `candidates.mjs`)

```ts
interface GeneratedTestCandidate {                  // plan §6 shape, extended
  schema: "atd.test-candidate/v1";
  id: string;                                       // ^[A-Za-z0-9][A-Za-z0-9._-]*$ (eval-harness case-id rule, run.sh:134,385)
  strategy: "intent_aware" | "mutation_guided" | "property_based";
  targetFile: string; testFile: string;             // testFile relative to /tests
  framework: "vitest" | "node:test";                // must match the target repo's existing convention
  testSha256: string;
  requirementRef: { specSha256: string; quote: string } | null; // quote must occur verbatim in the spec
  failureHypothesis: string;                        // hypothesis, never a claim of defect
  killsMutantIds?: string[];                        // mutation_guided only
  seed?: number; runs?: number;                     // property_based: recorded, injected via FC_SEED
  provenance: { baseCommit: string; candidateCommit: string; sourceDiffHash: string;
    modelId?: string; modelRevision?: string; generatorRole: string; promptSha256: string };
  trust: "untrusted";
}
```

Limits are enforced by the validator, not the model: ≤ 5 candidates per changed function and ≤ 25 per
run (configurable down only by trusted config). Test file ≤ 32 KiB. No `fetch`, `http`, `net`,
`child_process`, `fs` writes outside `/tmp`, or `--update-snapshots`. A candidate must contain at least
one assertion. Violations reject the candidate, and the rejection is counted in the discovery report.

### 7.3 `atd.execution-record/v1` and `atd.differential/v1` (producer: `atd-sandbox` runner only)

```ts
interface ExecutionRecord {
  schema: "atd.execution-record/v1";
  executionId: string;                              // unique per container run; fresh per stability sample
  candidateId: string; side: "base" | "candidate" | "mutant";
  revision: { commit: string; treeSha256: string }; mutantId?: string;
  testSha256: string; depsSnapshotSha256: string; lockfileSha256: string;
  image: { ref: string; digest: string }; nodeVersion: string;
  profile: { id: "atd-sandbox/v1"; policySha256: string };
  argv: string[]; env: Record<string, string>;      // full allowlisted env, verbatim
  seed: number | null;
  startedAt: string; endedAt: string; durationMs: number; exitCode: number; timedOut: boolean;
  outcome: "pass" | "fail" | "error";
  errorClass?: "compile" | "missing_fixture" | "no_tests_collected" | "timeout" | "oom" | "sandbox_preflight" | "infra";
  artifacts: { role: "junit" | "vitest_json" | "stdout" | "stderr" | "stryker_report" | "counterexample"; path: string; sha256: string }[];
}
```

`outcome` is derived only from the reporter JSON file. `pass` means ≥ 1 test executed, 0 failed,
exit 0. `fail` means ≥ 1 assertion failure recorded and no collection or compile error. Everything else
is `error`. Terminal text is never parsed (R4).

```ts
interface Differential {
  schema: "atd.differential/v1";
  candidateId: string; base: ExecutionRecord["executionId"]; candidate: ExecutionRecord["executionId"];
  matrix: "PASS->PASS" | "PASS->FAIL" | "FAIL->FAIL" | "FAIL->PASS" | "ERROR";  // any error on either side ⇒ "ERROR"
  environmentEqual: boolean;   // image digest, node, depsSnapshot, env, seed identical across sides
}
```

Runner obligations:

- Base and candidate run in the same spawn under one image and dependency snapshot.
- On infrastructure failure the runner exits non-zero **and writes nothing** to the transcript, so
  eval-harness records `ERROR` through `run.sh:682-687` instead of grading stale files.
- `spawn` deletes `atd-out/` before executing. This closes the stale-workdir hole at `run.sh:704`.

### 7.4 `atd.attestation/v1`: independently authenticated execution evidence

```ts
interface Attestation {
  schema: "atd.attestation/v1";
  runner: { id: "atd-sandbox"; scriptSha256: string; policySha256: string };
  ehRunId: string; caseId: string;
  executions: { executionId: string; recordSha256: string }[];
  differentialSha256: string; findingSha256?: string;
  trust: "ci-secret" | "separate-user" | "local-same-user";
}
// Signature: ssh-keygen -Y sign -n atd-execution@v1 -f <runner key> attestation.json → attestation.json.sig
// Verify:    ssh-keygen -Y verify -f <allowed_signers> -I atd-runner -n atd-execution@v1 -s attestation.json.sig < attestation.json
```

- The signing key and `allowed_signers` live outside every worktree and container mount (default
  `$EVAL_STATE_DIR/discovery/`, mode 0600). Only the trusted runner signs. Workers never receive the
  key path in prompts or the environment.
- Every artifact path and SHA-256 is also listed in the existing schema-1 grading manifest
  (`evidence.artifacts[]`, `lib/grading_manifest.sh:17-29`). `grade.sh` therefore keeps rejecting
  tampering (exit 13) with no format change.
- Grader behavior: a missing signature means check `UNAVAILABLE` → `INDETERMINATE`. An invalid
  signature, digest mismatch or unknown signer means check `ERROR` → exit 13.
- Independence statement: on a developer machine every OMP worker runs as the same OS user and could
  read a local key, so that evidence is labelled `local-same-user`. **Blocking gates may only rely on
  `ci-secret` or `separate-user` attestations.** v1 is warn-only, so local attestation is sufficient
  for reporting.

### 7.5 `atd.finding/v1` and the mapping onto eval-harness statuses

```ts
interface DiscoveryFinding {                        // plan §10 shape, extended
  schema: "atd.finding/v1";
  findingId: string; runId: string;                 // runId = eval-harness run_id
  classification: "VERIFIED_REGRESSION" | "SUSPECTED_REGRESSION" | "EXPECTED_CHANGE" | "EXISTING_FAILURE" | "INCONCLUSIVE";
  severity: "low" | "medium" | "high";              // from ChangeRisk.riskLevel of the target
  targetFile: string; testFile: string;
  baseResult: "pass" | "fail" | "error"; candidateResult: "pass" | "fail" | "error";
  reproducible: boolean;                            // eval-harness stability: performed ∧ byte_identical ∧ samples ≥ 3
  evidenceUris: string[];                           // run-dir-relative paths, each also in the grading manifest
  sourceCommit: string; candidateCommit: string;
  explanation: string;
  reproducer: { imageDigest: string; revision: string; testFile: string; testSha256: string; argv: string[]; seed: number | null };
  filter: { stageA: { passed: boolean; rules: { id: string; outcome: "pass" | "reject" | "downgrade" }[] };
            stageB?: { checkId: string; majority: "PASS" | "FAIL" | null; pass: number; fail: number; nulls: number } }; // supporting only
  attestation: { path: string; sha256: string; trust: Attestation["trust"] };
}
```

Each surviving candidate is one eval-harness case with runner `atd-sandbox`. It has one **required**
check `kind: discovery_finding`, one **optional** check `kind: discovery_test_health` (did the test
pass on base?) and an optional `llm_judge` (Stage B). The case `failed_check_id` is
`discovery_finding:<candidateId>:<matrix>`. That puts the matrix into `hash_checks`, so a FAIL
sample and an ERROR sample cannot hash as identical.

Deterministic classification (Stage A runs first; a reject drops the candidate as a counted
generation failure, not a finding):

| Matrix and evidence | classification | Required check status | Case status (existing) | Default exit | `--strict` |
|---|---|---|---|---|---|
| PASS→FAIL, Stage A passed, `requirementRef` verified in spec, `environmentEqual`, stability performed, byte-identical, ≥3 samples | VERIFIED_REGRESSION | FAIL | FAIL | 0 (warn-only) | 14 |
| PASS→FAIL lacking any of: spec support, reproducibility (flaky or not sampled) | SUSPECTED_REGRESSION | PENDING | NEEDS_REVIEW | 0 | 15 |
| PASS→FAIL or FAIL→PASS with a submitted `human_review` PASS record (reviewer, rubric_version, timestamp; `extended_graders.sh:54-75`) confirming intent; or FAIL→PASS (potential fix) | EXPECTED_CHANGE | PASS (evidence notes the change) | PASS | 0 | 0 |
| FAIL→FAIL | EXISTING_FAILURE | PASS (no candidate-introduced change); optional `discovery_test_health` = FAIL stays visible | PASS | 0 | 0 |
| any ERROR, `environmentEqual=false`, nondeterminism (Stage A), missing attestation | INCONCLUSIVE | UNAVAILABLE | INDETERMINATE | 0 | 16 |
| PASS→PASS | no finding (record says "no observed regression", never "bug-free") | PASS | PASS | 0 | 0 |
| invalid signature / digest mismatch / sandbox preflight failure | — (harness error) | ERROR | ERROR | 13 | 13 |

Reproducibility uses only the existing stability mechanism. The grader emits FAIL for a PASS→FAIL that
meets every criterion except reproducibility. One additive rule in `build_case_result`
(`lib/diff.sh:53-58`), scoped to `discovery_finding` checks, downgrades that FAIL to NEEDS_REVIEW
unless `stability.performed ∧ byte_identical ∧ samples ≥ 3`. Discovery runs must pass
`--stability-samples=3`.

Preserved unchanged: the `results.json` schema 3 fields and verdict words, the legacy `passed`
boolean, exit codes 0/2/12/13/14/15/16, JUnit/SARIF renderers, grading-manifest schema 1,
env-manifest schema 4, baseline schema 3 and single-writer baseline commands. Discovery never emits
the `REGRESSION` verdict and never writes `evals/baselines/`. Generated tests are provisional and
become permanent only through a human-reviewed PR to the target repository.

### 7.6 Stage B (optional semantic review)

- Stage B is an existing `llm_judge` check with `required: false`, run only for SUSPECTED candidates.
- Its prompt carries the task spec, relevant diff, test source, both execution records and log
  excerpts.
- Optional checks cannot change case status (`score.sh:449-456`), so deterministic evidence cannot be
  overridden. The result is recorded in `filter.stageB` as supporting evidence and uncertainty
  (agreement counts).

### 7.7 Consumption by Jev and QA Factory

`atd.repair-request/v1` (producer: `repair-request.mjs` from VERIFIED findings only):

```ts
interface RepairRequest {
  schema: "atd.repair-request/v1";
  findingId: string; ehRunId: string; resultsSha256: string;
  classification: "VERIFIED_REGRESSION";
  targetFile: string; reproducer: DiscoveryFinding["reproducer"];
  failureExcerpt: string;                           // ≤ 4 KiB, from the junit artifact
  requirementRef: { specSha256: string; quote: string };
  attempt: number; maxAttempts: number;             // maxAttempts = Jev budget.maxRepairRounds (3)
}
```

- **Jev v1 (no Jev code change):** the Jev test command is
  `scripts/eval/discovery/jev-gate.sh --base=<sha> --candidate=HEAD --mode=warn|block`. In `warn`
  (default) it always exits 0 and prints the verdict, finding counts and the results path into Jev's
  `outputTail`. In `block` it exits 14 only when ≥ 1 VERIFIED_REGRESSION carries a `ci-secret` or
  `separate-user` attestation. Jev's existing repair loop then applies: `findings.fix` is capped at 3,
  each round is appended to `testRounds`, a fix claim is not trusted, and the integration branch keeps
  the last known-good commit. SUSPECTED and INCONCLUSIVE never exit non-zero, so they cannot trigger
  repair. They surface in the run report for human review.
- **QA Factory (contract only; implementation blocked by B-5):** VERIFIED_REGRESSION →
  `CONFIRMED_DEFECT`; SUSPECTED_REGRESSION → `SUSPECTED_DEFECT`; every other class is not a finding.
  Human dispositions are stored separately and never rewrite the classification, matching
  `findings.py:126-136`.

## 8. Ownership remapping (exact paths)

### 8.1 Why ownership moves

The plan assigned "test discovery and candidate generation" to QA Factory. Code evidence rules that
out:

- QA Factory is a Python web-DOM campaign system with no diff, source or test-framework handling.
- It is not under version control (no PR path).
- Hosting generation there would create a second evaluation stack.

Generation therefore splits into two parts:

- the model step, a Jev-delegated OMP worker that writes candidates as untrusted data;
- deterministic validation, risk and mutation scoping, which live in eval-harness under
  `scripts/eval/discovery/`.

QA Factory keeps the consumer role defined in §7.7.

The plan gave "shared eval-harness registration" to the pilot task. The runner registration in
`run.sh` is inseparable from the execution task, so `run.sh` moves to `independent-execution`. All
other shared files stay with the pilot task. Owned path sets are disjoint.

### 8.2 Owned paths per downstream task

All paths are in a Jev-controlled checkout of `nano-step/eval-harness` at `002aafee` unless prefixed
`img2threejs:`.

| Task | Owned paths (exclusive) |
|---|---|
| discovery-generation | `scripts/eval/discovery/risk.mjs`, `scripts/eval/discovery/candidates.mjs`, `scripts/eval/discovery/mutation.mjs`, `scripts/eval/discovery/schemas/atd.change-risk.v1.json`, `scripts/eval/discovery/schemas/atd.test-candidate.v1.json`, `scripts/eval/tests/discovery_risk.sh`, `scripts/eval/tests/discovery_candidates.sh`, `scripts/eval/tests/discovery_mutation.sh` |
| independent-execution | `scripts/eval/runners/atd-sandbox.sh`, `scripts/eval/lib/atd_sandbox.sh`, `scripts/eval/lib/atd_attest.sh`, `scripts/eval/discovery/policy/atd-sandbox.v1.json`, `scripts/eval/discovery/schemas/atd.execution-record.v1.json`, `scripts/eval/discovery/schemas/atd.differential.v1.json`, `scripts/eval/discovery/schemas/atd.attestation.v1.json`, `scripts/eval/run.sh` (additive edits only at `:424-436` runner admission and `:706-720` generic resample branch), `scripts/eval/tests/atd_sandbox_failclosed.sh`, `scripts/eval/tests/atd_differential_matrix.sh`, `scripts/eval/tests/atd_stability_resample.sh` |
| evaluation-integration | `scripts/eval/lib/discovery_grader.sh`, `scripts/eval/lib/score.sh` (additive dispatch at `:44-73` and export at `:493`), `scripts/eval/lib/diff.sh` (additive discovery downgrade at `:53-58`), `scripts/eval/lib/grading_manifest.sh` (artifact collection at `:29`), `scripts/eval/discovery/classify.mjs`, `scripts/eval/discovery/schemas/atd.finding.v1.json`, `scripts/eval/tests/discovery_grader.sh`, `scripts/eval/tests/discovery_report_compat.sh` |
| orchestration-integration | `scripts/eval/discovery/jev-gate.sh`, `scripts/eval/discovery/repair-request.mjs`, `scripts/eval/discovery/schemas/atd.repair-request.v1.json`, `scripts/eval/tests/discovery_jev_gate.sh`. **No Jev or QA Factory paths** until B-5/B-6 are resolved |
| pilot-and-release-evidence | `examples/discovery-pilot/collision/**` (self-contained fixture: `package.json`, `package-lock.json`, `src/collision.ts`, `test/collision.test.ts`, `SPEC.md` with an explicit zero-size and touching-edge contract, `patches/clean-change.patch`, `patches/*-defect.patch`, `build-fixture-repo.sh`), `scripts/eval/tests/discovery_pilot.sh`, `package.json`, `README.md`, `CHANGELOG.md`, `POLICY.md`, `KNOWN_ISSUES.md`, `docs/discovery.md`, `docs/README.md`, `.github/workflows/tests.yml`; Phase 10 (after the pilot passes): `img2threejs:forge/stage4_review/discovery_domain_checks.py`, `img2threejs:forge/tests/test_discovery_domain_checks.py` |

The pilot fixture lives in eval-harness, not in `img2-plugins/pixi2d`. pixi2d has no collision code, and
adding product code to a skill plugin only to host a benchmark would misrepresent the product. The
fixture is labelled as a benchmark modelled on axis-aligned rectangle collision.

## 9. Blockers and prerequisites (implementation gate)

| ID | Blocker | Evidence | Required to proceed |
|---|---|---|---|
| B-1 | No eval-harness checkout under Jev control. The current run is single-repo (img2threejs) | `workspace.ts:48-58`; plan provisional paths do not exist | A Jev run (or manual branch) on a stable checkout of `nano-step/eval-harness` (push and admin verified). Suggested path: `/Users/hoainho/Document/Personal/eval-harness` |
| B-2 | Host has no `jq` binary | 47/57 suites fail with `jq: command not found` | Operator-approved install of `jq`, then re-measure `npm test` on `002aafee` to establish the eval-harness baseline |
| B-3 | No pinned Node image; the sandbox fails closed | `--pull never` → `No such image` | Operator-approved one-time pull of a Node 20 image. Record its `@sha256` digest in `atd-sandbox.v1.json` |
| B-4 | Vitest, fast-check and StrykerJS not installed | §4.5 | Explicit dependency approval, scoped to the pilot fixture lockfile and the dependency snapshot only. eval-harness runtime stays dependency-free |
| B-5 | QA Factory not under version control | `git log` → not a repository | User decision: initialize and publish, or accept consumer-contract-only integration |
| B-6 | Jev repository has no commits or remote, and `dist/` is the running controller | `git log` → no commits | v1 uses the test-command gate (no Jev change). Any Jev code change waits for a committed and published repository and must not rebuild `dist/` during a live run |
| B-7 | Pilot target code does not exist | §4.6 | Pilot authors the fixture (§8.2) with an explicit contract for zero-size rectangles and touching edges |
| B-8 | Local signatures are same-user | §7.4 | Blocking mode requires a CI-secret or separate-user signer. Warn-only is unaffected |

Stop decision: B-1, B-2 and B-3 each independently prevent safe, verifiable implementation of the
eval-harness-owned tasks. Per the assignment's stop rule, implementation of `discovery-generation`,
`independent-execution`, `evaluation-integration`, `orchestration-integration` and
`pilot-and-release-evidence` must not start in this img2threejs-bound run. Resume once B-1 to B-3 are
resolved; B-4 must be approved before the pilot.

## 10. Risks

- **Stale-evidence false reproducibility.** Without the `run.sh:706-720` fix and runner-side output
  clearing, stability would re-grade copied outputs and report `byte_identical: true` for a single
  execution. A test must prove each sample has a distinct `executionId`.
- **Status hashing.** `hash_checks` ignores `status`, so the matrix must be encoded in
  `failed_check_id` (§7.5).
- **JUnit semantics.** NEEDS_REVIEW and INDETERMINATE render as JUnit failures (existing behavior). CI
  consumers that block on any JUnit failure would block on warn-only discovery output. Publish
  discovery JUnit separately or rely on the exit code.
- **LLM judge egress.** `llm_judge` sends prompts to Anthropic from the host. Stage B must never
  include secrets, and test source is sent as data only.
- **Meta's 60% true-positive rate** means many SUSPECTED findings. Human-on-the-loop review must stay
  aggregate, and warn-only stays the default until pilot FP/FN numbers exist.

## 11. Evidence log (commands run in this session)

| Command (abridged) | Observed result |
|---|---|
| `gh api --paginate /user/repos …` filtered for eval/harness/qa/jev/pixi | `nano-step/eval-harness` (public, pushed 2026-09-30), `workspace-backup-nhonh/eval-harness` (private, 2026-09-25), `workspace-backup-nhonh/qa-harness` (Shell; not QA Factory), `img2threejs/pixi2d`, `img2threejs/plugin-jev` |
| `gh repo clone nano-step/eval-harness` → `/tmp/atd-audit/eval-harness`; `git log` | HEAD `002aafee` "Merge pull request #45"; `package.json` v0.5.0, `bin` → `scripts/eval/run.sh` |
| `bash scripts/eval/test.sh` (eval-harness, this host) | 10 PASS, 47 FAIL. Failures show `jq: command not found` (e.g. `score.sh: line 408`) |
| `type jq`; `bash -c 'command -v jq'` | `jq is a shell builtin`; child bash finds no `jq` |
| `git -C qa-agents-factory log` | `fatal: not a git repository` |
| `.venv/bin/python -m pytest -q -p no:cacheprovider tests/test_models.py` (QA Factory) | `14 passed` |
| `git -C jev-orchestrator log`; `git status --short` | `does not have any commits yet`; every file untracked |
| `node_modules/.bin/tsc -p tsconfig.json --noEmit` (Jev) | exit 0 |
| `readlink -f ~/.local/bin/jev` | `jev-orchestrator/dist/src/cli.js` (live controller) |
| `docker version` | Server 20.10.16 linux/arm64 |
| `docker run --rm --pull never --network none --read-only --tmpfs /tmp … --cap-drop ALL --security-opt no-new-privileges --pids-limit 64 --memory 256m --cpus 1 --user 65534:65534 … pgvector/pgvector:pg16 sh -c '…'` | `uid=65534`, `NET=blocked`, `ROOTFS=readonly`, `TMP=writable`, `CapEff: 0000000000000000`, `NoNewPrivs: 1`, 0 secret-like env vars |
| same flags plus `-v /tmp/atd-audit/eval-harness:/src:ro --tmpfs /work…` | `SRC=readonly`, `WORK=writable`, `/root` permission denied |
| `docker run --rm --pull never node:20-bookworm-slim true` | `No such image: node:20-bookworm-slim` (fails closed) |
| `docker run --rm --network none alpine:latest true` (early probe, without `--pull never`) | Started a registry pull that was cut off. `docker images` afterwards lists only `pgvector/pgvector:pg16`, so no image was retained. Later probes used `--pull never` |
| `ssh-keygen -Y sign -n eval-harness-discovery …`; `ssh-keygen -Y verify …` (OpenSSH 9.6p1) | `Good "eval-harness-discovery" signature …`; tampered input → `Could not verify signature.` |
| `npm view @stryker-mutator/core version` / `vitest` / `fast-check` | 10.1.1 / 5.1.0 / 4.10.2 (registry; not installed) |
| `grep` for collision/intersect/overlap/aabb in `img2-plugins/pixi2d` | No matches |
| `grep` for `sqlite` in eval-harness scripts; `eval_run` in nano-brain-go Go code | No matches in either |
| Reference reads R1–R6 | Content summarized in §3 (Meta article dated 2026-10-29; Stryker states and metrics; fast-check introduction and PBT concepts; Vitest reporters; Playwright visual comparisons; Promptfoo CI/CD) |
