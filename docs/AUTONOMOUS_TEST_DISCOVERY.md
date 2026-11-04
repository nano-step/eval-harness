# Autonomous Test Discovery

Discovery generates bounded behavioral tests for a Git change, executes the same test independently against base and candidate revisions, and feeds signed evidence into the existing eval-harness graders, stability sampler, reports and gates. It does not replace the harness, install another agent runtime, or create an evidence database.

The generator is not the grading authority. A test that fails only on the candidate is a hypothesis until the execution is comparable, independently repeated and supported by a trusted expectation review. A surviving mutant is a coverage gap, never proof of a product defect.

## Prerequisites

- Existing eval-harness prerequisites: Bash, Python, Git, jq and the bundled yq shim or compatible yq.
- A working Node.js >=18 on the host; Git >=2.30 for revision-option separation.
- OMP with a configured Sonnet `implement` role for live generation. The workflow enforces the requested model family and records the served model; it does not fall back to another provider/model.
- Docker and the image allowed by `scripts/eval/discovery/policy/atd-sandbox.v1.json`, already pulled. The runner never pulls an image or falls back to host execution.
- A trusted Linux dependency snapshot for Vitest/Stryker. The pinned pilot image runs Node 22, as required by the pilot's maintained tooling.
- `ssh-keygen` with SSH signing support for execution attestations.

The host Node installation and OMP executable must both be on PATH. Fix a broken host Node by prepending a working installation, not by dropping the rest of PATH.

## Trusted setup is separate from execution

The collision example pins Vitest, fast-check and Stryker in its lockfile. Build its snapshot explicitly:

```sh
IMAGE=node@sha256:4b150b48b4116e2a22f2c39cc27025fbf4f153e2078fd3b14d159fdb5c7279da
docker pull "$IMAGE"
bash scripts/eval/discovery/setup-deps.sh \
  --lockfile-dir=examples/discovery-pilot/collision \
  --out=/tmp/atd-deps \
  --allow-network
```

This acknowledged setup step uses `npm ci --ignore-scripts` inside Docker. The evaluated test containers have no network and cannot install packages. A snapshot must live outside case workdirs. Both revisions use the same read-only snapshot; revision/snapshot lockfile differences prevent a comparable differential result.

For another repository, use its trusted, reviewed package.json and lockfile rather than installing packages requested by a generated test.

## Run discovery

```sh
node scripts/eval/discovery/run.mjs run \
  --repo=/absolute/repository \
  --base=<base-commit> \
  --candidate=<candidate-commit> \
  --spec=/absolute/repository/SPEC.md \
  --framework=vitest \
  --dependencies=/absolute/dependency-snapshot \
  --out=/absolute/discovery-output \
  --state-dir=/absolute/trusted-eval-state \
  --max-model-calls=1 \
  --max-candidates=12
```

`node:test` is also supported for JavaScript tests. TypeScript candidates use Vitest. Generation follows the repository's existing test conventions; it does not invent a different testing framework.

Each invocation creates a fresh `round-NNN` directory and appends its round index. Existing rounds are not overwritten. Important outputs include:

- `risk.json`: changed targets, hunks, symbols, rule weights, skip reasons and Git/spec provenance.
- Generation request, prompt and OMP event/response evidence, including reported input/output/cache counters and cost when available.
- `candidates/<id>/candidate.json` and its test source; validation acceptance/rejection details.
- Existing harness `results.json`, `diff.md`, JUnit/SARIF exports and preserved per-case grading evidence.
- Review templates, a reproducer and `round-summary.json`.

The CLI prints `ATD_SUMMARY=<path>`. Exit 0 means the pipeline completed, not that every case passed. Read the result states and findings. Usage exits 2; execution/infrastructure errors exit 13; no runnable candidates exits 20; generation failure exits 21. Failed and inconclusive rounds are retained.

## Generation and static admission

`risk.mjs` reads Git objects without executing repository code. It skips dependency trees, lockfiles, generated files, deleted/binary files and non-source changes, recording why. Its tokenizer preserves restricted line-terminator and escaped-string distinctions; lexical doubt falls back conservatively to textual hunks. It is not a full TypeScript parser.

`candidates.mjs` constructs bounded intent-aware prompts and materializes only candidate manifests and test files from model output. The generator has no filesystem tools and cannot supply approvals or grading configuration. Its hashes and provenance are filled by trusted code, not copied from model claims.

Hard bounds are 25 candidates/run, 5 per changed function and 32 KiB/test. Because the candidate schema does not identify a function, the per-function limit is conservatively enforced as at most 5 candidates per target file. Configuration may tighten bounds, not raise them. Static admission rejects unsupported capabilities, unsafe paths/links, duplicate test hashes, skipped tests, snapshots, unbounded loops and obvious tautologies. This screening is defense in depth, not a sandbox or a proof that an assertion is correct.

A requirement link must quote at least 12 characters verbatim from the specification and bind its SHA-256. A matching quotation establishes provenance only.

## Differential evidence and stability

The `atd-sandbox` runner exports each revision separately and overlays the same admitted test. Source and dependencies are read-only. Confinement includes a non-root UID, no network, read-only rootfs, dropped capabilities, no-new-privileges, bounded memory/CPU/pids/files, tmpfs and a host deadline. Credentials, signing keys and the Docker socket are not mounted.

The host input directory and revision placement are separate. `runner_config.testsDir`
defaults to `tests` inside the case workdir. `testsRel` defaults to `"."` inside
the exported revision; generated cases set it explicitly. Thus the input
`tests/test/example.test.ts` executes as `/work/test/example.test.ts`, retaining
its `../src/...` imports. A raw runner case can explicitly choose `testsRel: "tests"`
for a flat test intended for `/work/tests/example.test.ts`. Neither choice
permits overwriting tracked files or traversing outside the export.

Outcomes come from structured framework reporters, not terminal text:

| Base | Candidate | Meaning |
|---|---|---|
| PASS | PASS | No regression observed by this test |
| PASS | FAIL | Potential regression; requires comparable, stable evidence and expectation support |
| FAIL | PASS | Expected change/improvement, not a new regression |
| FAIL | FAIL | Existing failure or invalid expectation, not a new regression |
| ERROR | any | Inconclusive execution; never a verified regression |
| any | ERROR | Inconclusive execution; never a verified regression |

Collection errors, no tests, runtime faults, timeouts and OOM are not assertion regressions. A mixture of assertion failures and runtime faults is an execution error. Environment mismatches are inconclusive.

The harness performs fresh executions for stability samples rather than regrading copied outputs. Confirmation requires at least three independently executed, consistent samples. Execution IDs must be distinct. Volatile transcript bytes are not evidence of semantic flakiness on their own.

`atd-out/` contains execution records, differential data, structured artifacts and `attestation.json` plus its SSH signature. `atd_verify` checks signatures, signer policy, every referenced digest and path binding. The existing grading manifest additionally binds replay inputs and stability evidence. Missing evidence is unavailable; tampering is an error, never an implicit pass.

## Review and replay

A trusted operator must inspect the actual test against the requirement, not merely approve its quote. Complete its emitted review template with reviewer, rubric, timestamp, rationale and verdict. Keep the exact attested candidate/test/spec/manifest hash bindings.

Store it outside the discovery output tree as:

```text
<trusted-approval-directory>/<candidate-id>.expectation-review.json
```

Then replay the same candidates, without another model call:

```sh
node scripts/eval/discovery/run.mjs run \
  --repo=/absolute/repository \
  --base=<same-base> --candidate=<same-candidate> \
  --spec=/absolute/repository/SPEC.md \
  --framework=vitest \
  --dependencies=/absolute/dependency-snapshot \
  --out=/absolute/discovery-output \
  --state-dir=/absolute/trusted-eval-state \
  --reevaluate=/absolute/discovery-output/round-001 \
  --approval-dir=/absolute/trusted-approval-directory
```

Replay still executes fresh base/candidate containers and stability samples. It does not relabel the old execution as new evidence. Missing, rejected or mismatched reviews cannot support confirmation.
Frozen replay retains the original proposal context, including the mutant IDs
shown to a mutation-guided generator, and records its source-summary/request
hashes. It refuses a different base/candidate revision and revalidates the
candidates; new prompt wording does not silently rewrite archived proposals.


## Scoped maintained mutation testing

`mutation.mjs` supports changed-hunk or changed-symbol scope. The executable `run.mjs mutation-evidence` workflow uses changed functions (`symbols`), including unchanged statements inside those functions; it does not mutate unrelated functions. Both comparison runs must use the same scope and configuration. Execution uses the same confinement with a writable tmpfs copy rather than mutating the repository:

```sh
node scripts/eval/discovery/run.mjs mutation-evidence \
  --repo=/absolute/repository --commit=<risk-candidate-commit> \
  --risk=/absolute/discovery-output/round-001/risk.json \
  --dependencies=/absolute/dependency-snapshot \
  --out=/absolute/mutation-baseline \
  --max-mutants=100
```

The mutant limit defaults to 100 and cannot exceed 500. A trusted reporter uses Stryker's official pre-execution planning event to record the count and abort an over-budget plan before mutant execution. Throwing from a reporter is insufficient because Stryker swallows reporter exceptions. Refusals retain signed budget evidence with no fabricated score.

The slim image lacks procps. A read-only procfs helper supports exactly the `ps -o pid --no-headers --ppid N` invocation used by Stryker's process-tree cleanup; other invocations fail. It is not a replacement system ps. Framework process groups and containers are cleaned up with bounded waits.

Killed/timeout mutants count as detected; survived/no-coverage mutants identify gaps; equivalent, invalid and unknown mutants are recorded separately. Unavailable measurements remain null. Compare baseline and generated-test mutation reports only for matching revision/configuration provenance and preserved source. To add passing generated tests, supply `--round=<round-dir>` and `--baseline=<mutation-baseline-dir>` to a new `mutation-evidence` invocation.
A supplied expectation review can veto a generated mutation test even when it
passes on both unmutated revisions. Rejected, malformed or hash-unbound reviews
exclude that test with a reason. Missing reviews remain advisory; a PASS review
does not independently elevate mutation evidence. Do not assert unspecified
diagnostic wording merely to kill a surviving string mutant.

The `mutation-evidence` command obtains count/comparison authority from the
verified seal at `<measurement>/sandbox` and its signed raw Stryker artifact,
not editable `evidence.json` or `normalized.json`. Its baseline must be an
existing-revision-test measurement with no generated overlay. It verifies that
baseline before Docker execution, binds the raw configuration bytes and tests
tree, and refuses comparison across incompatible signed environments. Preserve
the original trusted state or external allowed-signers file when replaying it.

The pilot report also verifies both signed raw reports and the generated test
tree before calculating its mutation comparison. Pass `--mutation-baseline`
and `--mutation-with` to `pilot-report` to select explicit retry directories;
`--state-dir` selects the trusted signer state. Different signed runner
fingerprints or environments make the comparison unavailable. A `Timeout`
counts toward Stryker's detected score but does not prove an assertion killed
a previously surviving mutant.


## QA Factory and Jev

The executable QA oracle adapter is `integrations/qa-factory/discovery.py`. Its absolute-path configuration selects trusted profiles, output/state directories, model, dependency snapshot and optional approval directory. Requests select a configured profile and revisions; they cannot supply arbitrary commands or environment variables. Example configuration and hook requests live under `examples/discovery-pilot/collision/config/`.

The trusted QA profile may set `model` and `requireModel` together; the latter
is the model-ID regular-expression guard passed to the pipeline. Without it,
the existing Sonnet guard remains in effect. The collision pilot derives an
exact guard from its explicit `--model` selector.

The adapter uses QA Factory's existing command-hook protocol. `command_hook_smoke.py` invokes the real `qa_factory.hooks.command_hook` from an existing checkout; it is not another QA runtime. Hook deadlines must exceed the configured pipeline deadline and cleanup grace. Output is bounded. Timeouts terminate owned process groups and remain inconclusive.

Jev uses its existing test-command and bounded repair loop:

```sh
bash scripts/eval/discovery/jev-gate.sh \
  --repo=/absolute/repository --base=<base> --candidate=HEAD \
  --spec=/absolute/repository/SPEC.md \
  --dependencies=/absolute/dependency-snapshot \
  --out=/absolute/gate-output --mode=warn
```

Warn mode always exits 0 but explicitly preserves and prints errors/non-PASS states. It must not be read as a pass assertion. Block mode is an explicit opt-in: eligible confirmed regressions exit 14; unverifiable execution exits 13. Suspected findings and mutation gaps never request automatic repair.

Repair requests are bounded by distinct candidate revisions for the same target/requirement. Repeated requests for the same commit do not consume another attempt. Stale evidence cannot be relabeled as a different candidate commit; corrupt ledgers fail closed. Exhaustion requires human review rather than an unlimited loop. Jev's own `maxRepairRounds` remains authoritative; no controller changes are needed.

## Independent promotion is stricter than local reporting

Local keys are stored outside worktrees under the configured state directory and yield `local-same-user` trust. They provide integrity checks, not independence from another process running as that user. Such findings remain advisory to the blocking/repair/QA-confirmation boundaries.

Independent promotion requires externally controlled `ATD_SIGNING_KEY_FILE`, `ATD_ALLOWED_SIGNERS_FILE` and `ATD_TRUST=ci-secret` or `separate-user`, plus the operator's original review from an explicit trusted approval directory. Configuring an external path alone is not proof that an organization has separated control correctly.

Downstream consumers never trust `verified`, class or trust flags in results JSON. They replay preserved evidence through existing `grade.sh`, verify signatures and compare the recomputed finding. Before replay, admission binds the generated case/workdir layout and admits only discovery check kinds, preventing a rewritten manifest from injecting a host shell check. Original review bytes must match the trusted approval store; rewriting both a review and its hash manifest is not approval.

For the QA adapter, list all three signer variables in trusted `passEnv` and the campaign's `secret_envs`. Default configuration forwards none of them. Local confirmation is mapped to suspected/review-required QA evidence, not `CONFIRMED_DEFECT`.

## Optional img2threejs product evaluation

`integrations/img2threejs/run.sh` evaluates a trusted-operator configuration
against an isolated revision; the target's TypeScript and browser code execute
only inside the pinned Docker sandbox. The opt-in Playwright policy does not
change the default Node policy. Dependency preparation is a separate trusted
network-enabled step using `setup-deps.sh --allow-network`, with install scripts
disabled.

```sh
ATD_IMG2THREEJS_PRODUCT_ROOT=/absolute/img2threejs \
  bash integrations/img2threejs/run.sh /absolute/empty-output \
  /absolute/repository <commit-sha> /absolute/dependency-snapshot \
  /absolute/external-baseline/approval.json
```

The configured target exports `createScene()` returning a Three.js `Scene`.
The existing product grader reports geometry, scene graph, materials,
animation, runtime and visual metrics separately; absent evidence is
`UNAVAILABLE`, not a zero or pass. The browser renders with fixed settings,
exports GLB and checks a native GLTFLoader round trip. Existing product GLB and
rig validators consume bounded signed artifacts; no product source is copied
or modified. The stricter `rig-payload.alpha` contract is opt-in.

Screenshot comparison requires a separately approved baseline outside the
output and matching browser/render provenance. Missing approval, changed
configuration or unverifiable evidence makes visual comparison unavailable.
Chromium uses `--no-sandbox` only inside the Docker boundary. The initial
fixture baseline must be visually inspected and explicitly approved; ordinary
evaluation never overwrites it.

## Limits and verification

- Docker shares a kernel/VM boundary; this is not a hardware-isolated executor.
- Tests and framework reporters share an in-container UID. Signed hashes bind the executed test and captured artifacts, not a mathematical proof that adversarial code could never influence reporter output. Review and controlled signer ownership remain necessary.
- The writable output mount has file-size/process/deadline limits but no filesystem-wide quota. Monitor host storage; an exhausted host/daemon is infrastructure failure, not a product finding.
- Repository Vitest setup/plugins are not executed. Trusted equal configuration is used on both sides; projects requiring special aliases/setup need an explicitly reviewed integration, not an unsafe fallback.
- Generation/static acceptance, operator approval and test persistence are different metrics. Replays must not be counted as new model calls or duplicate defects. Report fresh input, output, cached input and available cost separately; unavailable coordinator/worker totals are not inferred.
- The collision benchmark is an isolated fixture modeled on img2pixi2d behavior, not a claim that the inspected plugin contains that production module.

Run `npm test` for compatibility/security suites. Set `ATD_TEST_VITEST_DEPS` to a trusted Linux snapshot to exercise the live Vitest matrix rather than its optional skip. Run `scripts/eval/discovery/pilot.sh run`, review/replay, `gate` and `qa-hook` for real model/container/consumer evidence. Unit fixtures do not measure live detection quality or model cost. Observed results and current acceptance limitations are recorded in the [architecture audit](../autonomous-test-discovery-audit.md).
