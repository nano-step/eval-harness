# eval-harness v2: audit, research, architecture, and design

## Status and decisions

This document records the repository audit, ECC research, and pre-implementation design. The code audit is against local `@nano-step/eval-harness` 0.4.2. No implementation code was changed before completing the audit/research/design. The user explicitly authorized implementation after this design; unresolved items are deferred below rather than blocking the work.

**Decision:** evolve the current Bash/YAML/JSON system. Keep `run.sh`, old v2 case YAML, existing `checks`, OpenCode execution, Anthropic judge, per-case baselines, result directories, and NDJSON history. Add an artifact-first `grade` API so other harnesses can use the evaluator without invoking OpenCode. No SQLite, service, or second framework.

## 1. Current architecture audit

### Execution map

```text
npm bin / eval-harness
  └─ scripts/eval/run.sh
      ├─ dispatch baseline/status/promote/trend/accept/apply/ab/rebaseline/metaeval/calibrate
      ├─ reads <skills-root>/<skill>/evals/cases/*.yaml
      ├─ resolves project config, registry, preflight, mode, and daily budget
      ├─ materializes fixtures into isolated case workdir and takes per-case lock
      ├─ captures environment manifest; invokes OpenCode via lib/spawn.sh
      ├─ lib/score.sh runs every check; stochastic cases execute N isolated trials
      ├─ failed deterministic cases may be resampled for stability diagnostics
      ├─ lib/diff.sh compares baseline and current case results; lib/attribute.sh classifies evidence
      ├─ writes per-run results.json + diff.md; optional JUnit/SARIF
      ├─ appends history.ndjson, daily cost ledger, daily promotion stats
      └─ applies warn-only / strict / promotion exit behavior
```

Evidence: `package.json:23-38`; `scripts/eval/run.sh:39-47,155-225,227-355,394-594,597-673`; `scripts/eval/lib/spawn.sh:53-94`; `scripts/eval/lib/score.sh:23-68,375-413`; `scripts/eval/lib/diff.sh:26-146`.

### Existing data and interfaces

- **Cases:** YAML schema version 2 under `skills/<skill>/evals/cases/`; `id`, `prompt`, `mode`, `model`, `skills_loaded`, `setup.fixtures`, `budget`, `checks`. Stochastic fields: `samples`, `pass_threshold`, `temperature`, `ci_gate`, `ci_required_rate` (`run.sh:278-300,394-465`).
- **Graders:** the v0.4.2 audit found six check kinds in lib/score.sh, all aggregated with required checks. At that version, shell commands used a heuristic safety filter, not an OS sandbox. v0.5.0's implicit-safe path uses the constrained argv runner described in SECURITY.md.
- **Baselines:** per-case JSON under `evals/baselines/`; baseline/accept/rebaseline support checksums and portable manifests. Legacy baseline JSON is read by current code (`baseline.sh`, `accept.sh`, `rebaseline.sh`, `lib/stability.sh`, `lib/diff.sh`).
- **Attribution:** actual labels are `SKILL_CHANGED`, `CROSS_SKILL_CHANGE`, `FIXTURE_STALE`, `MODEL_CHANGED`, `UNKNOWN_DRIFT`; evidence is a changed-manifest-key diff (`lib/attribute.sh`).
- **Results:** `results.json` schema v2 with case checks, baseline status, stochastic data, attribution, stability, environment manifest, cost, duration and rerun path. Per-run artifacts include transcript, workdir, checks, environment manifest and stability JSON (`lib/diff.sh:73-146`, `run.sh:587-673`).
- **Storage:** local per-run directories, `history.ndjson`, daily budget NDJSON, daily promotion JSON, judge cache, per-case baselines. No SQLite/service. `trend` is an append-history reader; there are no immutable named release snapshots.
- **Runner/API:** one Bash CLI; execution is OpenCode-specific and judging is Anthropic-specific. No stable library/server API. Existing `scripts/eval/lib/score.sh` can score a prepared artifact set, but there is no public provider/harness-neutral grading command.
- **Quality gates/reporting:** baseline regression detection, `--strict`, promote, daily spend cap, Wilson lower-bound gate, meta-eval, judge calibration, 2-tier execution, JUnit/SARIF, pre-push and sync-publish. Stop hook remains a scaffold.
- **Tests/docs:** CI runs all `scripts/eval/tests/*.sh`, plus meta-eval/performance checks; `npm test` runs only `regression_inject.sh`. The directory contains 51 shell suites. README/skill/known-issues/OpenSpec prose is stale relative to current code (e.g. strict, apply, auto-promotion, stochastic eval, 2-tier, attribution class count).

### Existing support and gaps

| Capability | Current support | Gap |
|---|---|---|
| Baseline vs current | PASS→FAIL from baseline is `REGRESSION`; other failure is `FAIL` | Baseline comparison is not separated from eval intent |
| Deterministic evaluation | Six checks; all checks AND | Binary-only; no dimension outputs/optional graders |
| Repeated-run reliability | Stochastic trials, pass threshold, Wilson interval/gate | No named pass@k/pass^k; diagnostic FAIL resampling is not a success-rate estimate |
| Transcript/artifact | Literal text checks, file/JQ checks, text LLM judge | No product artifact score input, native multimodal evaluator, or trajectory assertions |
| Human review | Human labels calibrate the LLM judge | No per-evaluation review record/pending gate |
| Attribution | Hashed skills/fixtures/model evidence; cross-skill suspect list | Prompt/rubric/tool/environment classes and confidence/explanation missing; manifest changes are not causal proof |
| Quality/cost/reliability | Candidate token-derived estimated USD, case/run duration, daily budget | No per-dimension quality, tool/retry metrics, robust cost completeness, or resource-aware A/B deltas |
| Model comparison | Per-case model override and A/B skill comparison | No same-case model matrix or quality/resource report |
| History | Per-run files and NDJSON history | No release snapshot; no DB required for current scale |
| Product evaluation | Existing checks can test arbitrary files/JSON/text | No explicit product semantics, per-dimension scores, or generic artifact-adapter contract |

### Verified audit risks

- The current Darwin Bash is 3.2.57. Focused audit agents observed `mapfile: command not found` in `run.sh`, `apply.sh`, and related scripts; A/B could turn a failed run into an empty comparison and false PASS.
- `hooks/pre-push:86-94` uses `if ! command; then exit_code=$?`, capturing the inverted status and potentially swallowing a blocking eval result.
- `promote.sh` documents seven green days but its ordinary promotion path only checks for one recent run and zero bypasses; only `--check`/`--auto-promote` enforce daily green stats.
- `ab.sh` suppresses child exit codes and can synthesize empty results; `accept`/baseline commands locate the globally newest run rather than matching a run identity. These are design risks; fixes are scoped below where they affect eval validity.

## 2. ECC research and comparison

The current ECC skill is at [`.agents/skills/eval-harness/SKILL.md`](https://github.com/affaan-m/ECC/blob/main/.agents/skills/eval-harness/SKILL.md) on `main`; GitHub showed ECC v2.2.1 (2026-09-08) as latest at research time. Exact `main` commit SHA was not captured. Full evidence, scope limits, issue history, and a before-change comparison table are in [`ECC_RESEARCH.md`](./ECC_RESEARCH.md).

**Adopt:** define eval criteria before code; explicit capability/regression intent; pass@k/pass^k vocabulary; deterministic-first and multiple grader types; human review as a real pending state; release-oriented reports. **Keep stronger local work:** baselines/manifests, portable baselines, Wilson statistics, deterministic meta-eval, judge calibration/abstention, cross-skill evidence, cost ledger, and run history. ECC does not provide a detailed trajectory evaluator, score schema, calibration math, or causal attribution. Do not copy its suggested thresholds or unverified slash-command examples.

## 3. v2 architecture

```text
Candidate execution adapter (OpenCode now; Janus/other harnesses later)
       │
       ├─ candidate artifact/workdir + transcript
       ├─ optional normalized trajectory.jsonl
       ├─ optional product-metrics.json / human-review.json
       └─ versioned grading-manifest.json (case, run, evidence refs/digests, provenance)
                    │
                    ▼
            Evaluation / grade API
              ├─ existing deterministic checks (code/rule/artifact/transcript)
              ├─ metric-score grader (generic JSON evidence; 0..1 per dimension)
              ├─ trajectory grader (normalized event contract)
              ├─ LLM judge (existing majority/calibration path)
              └─ human-review record (PASS/FAIL/PENDING; missing never passes)
                    │
                    ├─ required checks: legacy AND behavior by default
                    ├─ optional checks and per-dimension weighted scores
                    └─ explicit hard minima; no universal weighted quality score
                    │
                    ▼
          Case result + reliability + attribution/evidence
                    │
          separate quality / reliability / resource dimensions
                    │
          configurable gates: regression, capability, product, reliability,
          review state, cost/latency completeness and A/B comparison
                    │
          results.json v3 + per-run evidence files + existing NDJSON history
```

### Evaluation taxonomy with behavior

`eval_type` accepts `regression`, `capability`, or `product`; omitted legacy fields normalize to `regression` so old cases retain current baseline behavior.

- **Regression:** baseline comparison is active. Existing PASS→FAIL semantics remain; no baseline means `FAIL`, not an invented regression.
- **Capability:** evaluates the declared positive ability independently of any baseline. A capability failure is `FAIL`, never baseline-attributed `REGRESSION`; historical baseline data is retained but does not decide the capability verdict.
- **Product:** requires/produces per-dimension product evidence via generic metric/artifact graders. It may optionally compare a baseline with `compare_to_baseline: true`; product evaluation and regression comparison are distinct axes. It never assumes mesh/image semantics in core.

Existing `checks` remain the public case contract. No forced `graders` rename or bulk fixture rewrite.

### Grader composition and product score contract

Each check can opt into `required` (default `true`), `dimension` (default check kind), and positive `weight` (default 1). All required checks must pass, preserving legacy AND behavior. Optional checks report evidence/score but do not silently become gates. Product dimensions are weighted only within that named dimension; missing evidence makes that dimension unavailable rather than dropping it. No global score is emitted unless a future case explicitly supplies a calibrated aggregation policy.

Add generic `metric_score`: reads a numeric score in `[0,1]` from a JSON artifact path, records the observed score/evidence, and applies an explicit `minimum` when configured. Artifact producers can be code/rule/image/model adapters outside the core. Existing LLM judge remains binary majority in this iteration; model calibration/abstain data is preserved.

Add `human_review`: consumes a versioned JSON review record containing reviewer pseudonym, rubric version, verdict or score, timestamp, rationale/evidence. Missing review is `PENDING`/`NEEDS_REVIEW`, not PASS or candidate FAIL. This is an importable grading contract, not a review queue/UI or consensus workflow.

### Provider/harness-neutral grading and evidence manifest

Add `eval-harness grade --manifest=<grading-manifest.json>`. The manifest has its own schema version and identifies `case_id`, `run_id`, case-file digest, evaluation type, relative evidence paths (workdir, transcript, trajectory, product metrics, human review), per-artifact status/digest, and runner/model/grader provenance. The grade API verifies declared digests when present, preserves missing/unavailable distinctions, and emits the same grader-result structure used by `run`. `run` remains an OpenCode adapter that writes this manifest; Janus/other harnesses can generate one without changing evaluator code.

No arbitrary plugin execution in core. Domain adapters produce declared evidence files; the evaluator does not execute untrusted adapter commands.

### Generic trajectory contract

Trajectory is JSONL with one event per line and monotonically increasing `seq`; required identity is `type`, optional fields include `tool`, `skill`, `call_id`, `retry_of`, `status`, `verification`, `artifact`, `elapsed_ms`, and measured usage. Core rules can require events/skills, allow/forbid tool names, bound tool calls/retries, require verification, and require a failed verification to be followed by an explicitly linked successful repair/verification. Metrics count explicit normalized `tool_call`, `retry`, failed result, verification, and verified-repair events. Missing trajectory is unavailable, never zero calls. Raw provider transcript is retained; the contract does not claim comparable semantics until an adapter supplies them.

### Reliability mathematics and gates

For one fixed case/configuration, let $X_i=1$ iff isolated attempt $i$ passes all required checks, $n$ be valid attempts, $x=\sum X_i$, and $\hat p=x/n$.

- **Success rate / pass@1:** $\hat p$.
- **pass@k:** probability at least one of $k$ IID attempts succeeds, $1-(1-p)^k$; report the plug-in estimate $1-(1-\hat p)^k$.
- **pass^k:** probability all $k$ IID attempts succeed, $p^k$; report $\hat p^k$.
- Use the current two-sided 95% Wilson interval $[L,U]$ for $p$; transform monotonically: pass@k interval $[1-(1-L)^k,\;1-(1-U)^k]$; pass^k interval $[L^k,U^k]$. $n=0$ is unavailable. Require $1\le k\le n$ and record $x,n,k$.
- This IID interpretation applies only to repeated isolated runs of the **same case, prompt/rubric, model, tools and environment**. Do not pool different cases, count retries/conditional failure-stability reruns as trials, or claim independence the adapter cannot support. Mark reliability inference unavailable when trial identity/configuration is not comparable. Existing `pass_threshold` count semantics and current Wilson gate remain distinct and backward compatible.

Promotion predicate is explicit: all required graders pass; no required human review is pending; regression count is within the configured limit; any declared reliability lower-bound gate passes; each declared product dimension minimum passes; and any hard resource gate has complete required measurement. Unknown resource evidence never becomes zero or silently passes a hard gate. Cost-rise warnings remain warnings, not gates. `--strict` blocks capability/product FAIL and pending review with distinct exit codes; regression retains exit 12.

### Attribution and provenance

Preserve existing classes. Capture prompt and grader/rubric hashes; classify environment deltas from already recorded platform/runtime values; accept an optional externally supplied tool-manifest hash before emitting `TOOL_MANIFEST_CHANGED`; use stability divergence for `NON_DETERMINISTIC_DRIFT`. Add `RUBRIC_CHANGED` only because grader definitions are directly fingerprinted. Old baselines lacking new hashes ignore those new fields rather than falsely attributing every old baseline.

Every attribution includes changed-key evidence, an explanation, and an `evidence_strength` label (`limited` or `direct_hash_observation`, not a probability), plus `also_observed` when multiple inputs moved. Labels mean “observed associated change,” not causal proof. Keep `CROSS_SKILL_CHANGE`; do not claim `CROSS_SKILL_INTERACTION` from a changed non-SUT skill alone. If evidence is incomplete, retain `UNKNOWN_DRIFT`.

### Quality, resources, and model comparison

Keep dimensions separate: product dimension scores; reliability estimates/intervals; candidate tokens; LLM-judge tokens/cost when reported; estimated USD with pricing provenance; wall-clock duration and scope; explicit trajectory tool/retry counts. Each resource records `measured`, `estimated`, `partial`, or `unavailable`. `ab` adds same-case `--base-model`/`--candidate-model`, per-dimension score deltas, token/cost/latency/reliability deltas, and an opt-in warning when quality improves while known cost rises beyond a caller threshold. Missing resource data blocks only an explicitly configured hard resource gate; it remains visible as unknown. No universal scalar objective.

### img2threejs product adapter

The real local `img2-plugins/plugin-img2threejs` already provides a strong adapter seam:

- `scripts/character_audit.sh` runs separate JSON-producing geometry/self-intersection, penetration, and UV gates and records each exit status.
- `forge/stage4_review/geometry_integrity.py` reports topology, normals, self-intersection, seams, triangle budget and LOD validity; `turntable_gate.py` separately reports required azimuth coverage, segmentation reliability, silhouette collapse and holes.
- `scripts/capture_threejs_playwright.py` captures the actual browser canvas and fails closed when runtime/capture contracts are absent. `forge/stage4_review/render_bridge.py` records reference/capture paths, SHA-256, dimensions, viewport, DPR, renderer/Three version, readiness signal and console errors.
- `forge/stage4_review/vlm_gate.py` keeps deterministic hard failures authoritative, aggregates model samples by median, reports spread as uncertainty, checks VLM claims against geometry, and allows calibrated/explicit thresholds. `docs/TOKEN_COST.md` labels token numbers estimates, not measured benchmarks.

The img2threejs adapter—not core—converts those artifacts into generic dimension records such as `geometry_integrity`, `proportions`, `composition`, `object_completeness`, `visual_similarity`, `editability`, `animation_readiness`, and `runtime`. It references the raw gate/render manifests and hashes; it reports subjective/uncalibrated VLM outputs as uncertain and may supply a human review record. Performance, candidate/judge tokens, cost, and generation time remain separate resource metrics. The fixture dogfood will exercise this generic record shape; it will not claim a live mesh/render or calibrated VLM result.

### Compatibility, versions, tests, and deferred work

- Read existing case schema-v2 unchanged; optional v2 fields are additive. Old cases normalize to regression/required-AND.
- Bump `results.json` and baseline schema to v3 and environment manifest to v4 under `POLICY.md`; baselines retain `source_run_id` to resolve grading-manifest refs. Readers accept old baseline/result fields and preserve historical files. No destructive history migration.
- Fix Darwin Bash-3 portability (`mapfile`) and pre-push exit propagation before relying on new gates. Correct manual promotion criteria and make A/B fail closed on missing subruns.
- Permanent tests cover legacy compatibility, taxonomy/baseline behavior, metric dimension gates/missing data, human pending vs recorded, trajectory metrics/missing trajectory, pass@k/pass^k boundaries/Wilson transforms, attribution evidence/backward baselines, cost completeness/A-B deltas, strict exits, and the real hook status path.
- Dogfood uses 10 deterministic fixtures for capability, regression, repeated-run reliability, pass@k/pass^k, multi-grader, trajectory, attribution, resources, gates, and img2threejs product evidence.
- Deferred: SQLite, generic service API, arbitrary plugin execution, native image/VLM provider, human-review UI/queue/consensus, calibrated default product weights, automatic model routing, causal attribution, sequential/Bayesian sampling, and universal vision thresholds.

## 4. Implementation and dogfood status

Design review completed before implementation. This section records the v0.5.0 working-tree delivery; the release remains unreleased.

### Implemented

- Kept case YAML schema v2 and the Bash/OpenCode execution adapter. Added explicit regression/capability/product intent, independent baseline-comparison control, typed outcomes, required/optional checks, named weighted quality dimensions, and metric_score, trajectory, and human_review graders.
- Added repeated-trial pass@k/pass^k estimates with Wilson-transformed bounds and an explicit IID assumption; legacy pass-threshold count gates remain distinct.
- Added `eval-harness grade --manifest=...` for externally produced evidence. Schema-1 manifests bind case, workdir tree, available transcript/artifacts/environment manifest by digest; grade validates paths within the manifest root and rejects tampering. It does not spawn a model.
- Wrote results schema 3, environment-manifest schema 4, baseline schema 3, and A/B result schema 2. Legacy case files and schema-2 baselines remain readable; new baseline records retain `source_run_id` so grading-manifest references resolve to the producing run.
- Added prompt/rubric/tool/environment attribution evidence, typed cost/resource availability, exact-run baseline/accept/rebaseline selection, model-specific A/B comparisons, history filters, unknown-cost budget gating, and strict typed exits. Attribution reports observed associations, not causal proof.
- Fixed Darwin Bash-3 `mapfile` incompatibilities, pre-push exit propagation, promotion readiness, A/B fail-closed behavior, and case/error paths that previously could disappear or look successful.

### Dogfood and verification

- `scripts/eval/tests/v2_dogfood.sh` exercises ten deterministic fixtures spanning eval intent, grader composition, reliability, trajectory, attribution, resource availability, gates, and product evidence. Product fixtures model generic img2threejs-style evidence; they are not live mesh or calibrated-VLM results.
- `scripts/eval/tests/baseline_provenance.sh` exercises exact source-run recording across baseline, accept, and rebaseline; default accept selects the newest run matching the requested case and refuses failed or unrelated runs.
- `npm test`: all 58 evaluation test suites passed, including the A/B model-override and grading-manifest integrity integrations.
- Offline meta-evaluation: 0/3 false negatives, 0/2 false positives, and 3/3 attribution cases correct. Real OpenCode was excluded from `PATH`; each scenario used its temporary stub.
- Mermaid validation passed for README and the research/design/benchmark docs (4 files, 2 Mermaid blocks). `npm pack --dry-run` listed 139 package files, including `JANUS_BENCHMARK.md`, POLICY.md, and KNOWN_ISSUES.md. The Janus 0.1.10 offline benchmark is recorded there; it is not ready as an execution adapter.

### Boundaries and deferred work

No real product image/mesh session, provider token charge, or VLM calibration was claimed. Hashes detect evidence changes but do not authenticate authorship. The grader has no remote artifact fetch, signature trust root, reviewer dispatch/UI, or arbitrary plugin loading. See [`KNOWN_ISSUES.md`](../KNOWN_ISSUES.md) for active limits. Deferred architecture remains explicit in §3; no placeholder adapter or unfinished feature was added.
