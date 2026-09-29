# ECC evaluation research

## Scope and source snapshot

ECC is Everything Claude Code. The current repository is `affaan-m/ECC`; the eval-harness skill is at [`.agents/skills/eval-harness/SKILL.md`](https://github.com/affaan-m/ECC/blob/main/.agents/skills/eval-harness/SKILL.md) on `main`. GitHub's [release list](https://github.com/affaan-m/ECC/releases) marked v2.2.1, dated 2026-09-08, as latest at research time. No commit SHA was captured, so this report identifies the live branch/file, not a commit-pinned checkout.

Sources reviewed: [ECC site](https://ecc.tools/), [Skills catalog](https://ecc.tools/skills), current eval-harness and agentic-engineering skills, [harness-audit command](https://github.com/affaan-m/ECC/blob/main/commands/harness-audit.md), [harness-audit scoring script](https://github.com/affaan-m/ECC/blob/main/scripts/harness-audit.js), and the GitHub issues/PRs linked below. Browser tab attachment failed in this environment; upstream details were obtained from current official GitHub/site pages through web search. Exact `main` HEAD remains unverified.

## What ECC's eval-harness skill actually provides

The skill is a workflow guide, not a standalone eval service. Its sections cover activation, philosophy, capability/regression eval types, pass^k, define-before-code workflow, integration patterns, storage, best practices, and an authentication example.

- **EDD:** define success criteria and evals before implementation; record a baseline; implement in small verifiable tasks; rerun and report. ECC's `/eval define`, `/eval check`, and `/eval report` are integration-pattern examples, not verified executable implementations in the skill.
- **Capability eval:** test a newly requested behavior against explicit criteria.
- **Regression eval:** preserve existing behavior after changes.
- **Product eval:** use evaluations when behavior quality cannot be represented by unit tests alone. ECC describes code, rule/schema, model, and human graders; recommends pass@1, pass@3, and pass^3; warns against overfitting, happy-path-only cases, ignoring cost/latency drift, and flaky graders.
- **Reliability guidance:** pass@k means at least one success among k attempts; pass^k means all k attempts succeed. The skill suggests capability pass@3 ≥ 0.90 and release-critical regression pass^3 = 1.00. These are recommendations, not evidence-backed universal thresholds. It gives no sampling estimator, independence requirements, confidence interval, or calibration procedure.
- **Artifacts:** `.claude/evals/<feature>.md` for eval definitions, `.claude/evals/<feature>.log` for run history, and `docs/releases/<version>/eval-summary.md` for a release snapshot. The skill does not define schemas or migration/retention rules for these files.

The product-evals subsection does **not** define a universal product-quality taxonomy, grader weighting/disagreement policy, standard metrics schema, model-judge calibration, cost/latency measurement formula, or evaluator plugin API. It is useful process guidance, not a complete technical engine design.

The separate ECC `agent-evaluator` is a response-quality scorecard (accuracy, completeness, clarity, actionability, conciseness). That is not an execution-trajectory evaluator and should not be conflated with tool-call/session analysis.

## ECC versus eval-harness before this change

| ECC concept | Current eval-harness before v2 | Gap / classification | Recommendation |
|---|---|---|---|
| Define evals before coding (EDD) | Run/baseline/regression workflow exists; no mandatory definition-first loop | Missing and worth adopting | Add define → baseline → implement → evaluate → report guidance; do not claim slash commands exist. |
| Capability vs regression taxonomy | Regression baselines are explicit; capability cases can run but are not classified separately | Partial; capability type missing | Add behaviorally meaningful type semantics, preserving existing regression defaults. |
| Product evals | Generic file/JQ/text checks only; no product dimensions or first-class type | Missing and useful for img2threejs | Add generic metric/artifact/trajectory contracts; keep domain axes in adapters/cases. ECC itself does not supply a detailed product schema. |
| Deterministic/code graders | Shell, JSON-path, file, and literal transcript checks; offline meta-eval | Already supported | Keep deterministic-first grading and evaluator self-tests. |
| Rule/schema graders | Narrow JQ-path and shell assertions; no generic numeric score/schema grader | Partial and worth strengthening | Add bounded generic rule/metric support, not an opaque product score. |
| Model judge | Anthropic text judge with majority voting, cache/retries, abstention, and human-gold calibration | Already supported more deeply than ECC's workflow guidance | Keep, expose judge provenance and limitations; avoid duplicating calibration. |
| Human grader | Human labels calibrate the LLM judge; no per-evaluation human verdict/pending state | Partial | Add an explicit pending/reviewed evidence state; missing review must never pass. |
| pass@k | Stochastic repeated runs, threshold, Wilson interval/gate; public docs are stale | Partial | Expose named metrics and exact formulas while retaining existing threshold behavior. |
| pass^k | No all-k-success reliability metric; failure stability sampling is not pass^k | Missing and useful | Add separate all-success metric/gate; never conflate with stability resampling. |
| Suggested pass@3/pass^3 thresholds | Wilson gate is caller-configured | Fixed defaults are missing but unnecessary | Do not hard-code ECC's recommended thresholds as universal policy; let the caller choose risk thresholds. |
| Multi-judge | Majority vote over repeated judge calls | Partial; no heterogeneous judge panel | Keep simple majority until provider-neutral judges and calibration exist. |
| Model/harness comparison | Per-case model override, 2-tier run, manifest model identity, A/B skill comparison | Partial | Add same-case comparison with quality dimensions and resource deltas; no automatic routing. |
| Trajectory/session scoring | Transcript is retained but sequence, skill choice, tool calls, retries, verification, and repair are not graded | Missing; a local extension, not a verified ECC skill feature | Add a generic normalized event contract and trajectory grader. |
| Quality × cost × reliability | Token/cost/duration exist, but no per-dimension quality or comparison/gates | Partial | Report separate dimensions and deltas; never impose a universal aggregate. |
| Attribution | Manifest deltas, cross-skill suspect list, portable baselines, and meta-eval | Stronger than ECC's unspecified attribution | Preserve it; only add causes supported by observable provenance and expose confidence/evidence. |
| Evaluation history | Per-run JSON/NDJSON trend history and per-case baselines/rebaseline exist | Partial: no immutable named release snapshot | Preserve current history; optionally associate baselines/results with release or commit identity. |
| Deterministic harness scoring | ECC `harness-audit.js` uses fixed weighted rules after an earlier scoring dispute | Already supported more directly by local meta-eval/calibration | Adopt inspectable scoring rules; retain the local known-truth FP/FN/attribution corpus. |
| Consumer-project portability | Local skill-root discovery and per-repo registry exist; candidate execution remains opencode-specific | Partial | Keep root discovery; define runner/trajectory adapters before adding a second runtime. |
| ECC `/eval` slash commands | Examples appear in workflow guidance; executable implementation not verified | Missing but unnecessary as a separate syntax | Keep one CLI/API; provide equivalent definition/run/report functions without copying command names. |

## Other ECC evidence and lessons

- [`skills/agentic-engineering/SKILL.md`](https://github.com/affaan-m/ECC/blob/main/skills/agentic-engineering/SKILL.md) describes an eval-first loop: define completion criteria, write capability/regression evals, baseline, split work into verifiable tasks, implement, and compare.
- [`commands/harness-audit.md`](https://github.com/affaan-m/ECC/blob/main/commands/harness-audit.md) and [`scripts/harness-audit.js`](https://github.com/affaan-m/ECC/blob/main/scripts/harness-audit.js) use deterministic, weighted, rule-based scoring across applicable categories. This is a repository audit tool, not the eval-harness engine.
- [Issue #534](https://github.com/affaan-m/ECC/issues/534) documents historical criticism of nondeterministic harness-audit scoring; [PR #524](https://github.com/affaan-m/ECC/pull/524) is associated with the deterministic scripted-rubric fix. Lesson: show rules and evidence, not just a score.
- [Issue #979](https://github.com/affaan-m/ECC/issues/979) reported that harness-audit was hard-coded to ECC and unhelpful for consumers; [PR #1014](https://github.com/affaan-m/ECC/pull/1014) added consumer-project/root handling. Lesson: adapters and paths must target the evaluated system, not the evaluator repository.
- [Issue #2674](https://github.com/affaan-m/ECC/issues/2674) reports scoring extraction, Bash/macOS compatibility, and missing Playwright tool permission problems in ECC's separate GAN harness. This is an issue report, not independently reproduced here. It is relevant as a warning: validate the configured evaluation path and permissions, not just the prompt that describes it.

## Adoption summary

Adopt ECC's EDD lifecycle, capability/regression distinction, pass@k/pass^k vocabulary, multi-grader mindset, and release-oriented reporting. Keep and strengthen the local baseline/manifest attribution, Wilson interval, deterministic meta-eval, judge calibration, cost ledger, and explicit abstention handling. Do not copy ECC's suggested fixed thresholds, file layout, slash-command examples, or imply that ECC provides a trajectory evaluator. The local normalized-trajectory and quality/cost/reliability design are extensions driven by the user's Janus and img2threejs requirements, not ECC features.
