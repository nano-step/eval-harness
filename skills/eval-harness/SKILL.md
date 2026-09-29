---
name: eval-harness
description: Run, grade, baseline, accept, rebaseline, or compare skill evaluations. Use for regression checks, capability or product metrics, human review, A/B comparisons, and evaluation-harness questions. Interpret typed statuses and evidence rather than treating every nonzero check as a regression.
compatibility: opencode 1.15.10+
version: 0.5.0
---

# eval-harness

Typed evaluation harness for OpenCode skills, with a provider-neutral grader for externally produced evidence. Use repository commands; never infer results from a baseline label or a missing artifact.

## Case contract

Each case has an eval_type:

- regression (default): compare against an existing baseline.
- capability: test declared capability; baseline comparison is off unless explicitly enabled.
- product: report independent named quality dimensions; baseline comparison is off unless explicitly enabled.

Required check outcomes gate the case. Optional checks report but do not gate. Product dimensions use per-dimension weighted means; do not compute or invent a global product score.

Result statuses:

- PASS: every required gate has measured passing evidence.
- FAIL: at least one required, measured grader failed.
- ERROR: malformed evaluation configuration or harness/scorer execution error.
- NEEDS_REVIEW: a required human review is pending.
- INDETERMINATE: required evidence is unavailable or a grader abstained.

A regression is only a compared case whose baseline passed and whose current status is FAIL. Capability/product failures are not regressions unless compare_to_baseline is explicitly true. Missing evidence never becomes PASS or a zero score.

## Commands

Run local deterministic suites:

    npm test

Run a skill or one case:

    eval-harness run --skill=<name>
    eval-harness run --skill=<name> --case=<case-id> --strict

Strict exits: 12 regression, 13 harness error, 14 measured failure, 15 pending review, 16 indeterminate evidence. Without --strict, evaluation failures remain recorded as typed warn-only results.

Establish a baseline only from a passing run:

    eval-harness baseline --skill=<name> [--case=<case-id>] [--portable]

Accept one passing run; pass --run=<run-id> to select it exactly:

    eval-harness accept --skill=<name> --case=<case-id> --run=<run-id>
    eval-harness accept --skill=<name> --case=<case-id> --run=<run-id> --bless-env --yes

Use --bless-env only when the changed environment is intended. Rebaseline refuses ERROR, NEEDS_REVIEW, and INDETERMINATE evidence. --accept-model-change is an explicit override for a genuine model upgrade, and writes an audit event.

Grade external artifacts without invoking a model:

    eval-harness grade --manifest=<grading-manifest.json> --strict

Schema-1 manifests bind the case file, workdir tree, transcript, referenced artifacts, environment manifest, IDs, and provenance with digests. The grader confines paths to the manifest root and rejects changed content.

Compare two skills, optionally under different models:

    eval-harness ab --base=<skill-a> --candidate=<skill-b> --base-model=<provider/model-a> --candidate-model=<provider/model-b>

A/B reports per-case statuses, per-dimension deltas, and resource coverage. --warn-cost-increase-pct is warning-only; it is not a quality gate.

## Check kinds

- shell, jq_path_contains, file_exists: deterministic workdir evidence.
- output_contains, output_not_contains: literal transcript evidence; missing transcript is unavailable, not proof of absence.
- llm_judge: model-judged rubric; unresolved votes are indeterminate, never fabricated PASS.
- metric_score: JSON number in [0,1], optional minimum, named dimension, and positive weight.
- trajectory: ordered JSONL events with strictly increasing unique seq values and declared rules.
- human_review: sidecar record with reviewer, rubric version, timestamp, and PASS/FAIL verdict; missing or pending record requires review.

Cases must include at least one required grader. Invalid types, empty checks, and all-optional checks are ERROR.

## Reliability, resources, and provenance

For repeated attempts of one case/configuration, pass@k = 1-(1-p)^k and pass^k = p^k; Wilson bounds are reported. IID is an explicit assumption, not empirically verified. Stability reruns do not count as independent reliability samples. Do not pool different cases or configurations.

Token, cost, and duration fields carry measured/partial/unavailable coverage. Unknown cost is null, never zero. With EVAL_BUDGET_USD enabled, unmeasured daily spend is recorded as unavailable and blocks later budget-gated runs until reconciled.

Environment manifest schema 4 captures model/runtime/platform, skill/bundle/fixture hashes, prompt/rubric hashes, and an optional tool-manifest hash. Legacy schema-2/3 baselines remain comparable; new hashes are ignored when absent from a legacy baseline.

Attribution classes describe changed evidence, not causation: SKILL_CHANGED, CROSS_SKILL_CHANGE, FIXTURE_STALE, MODEL_CHANGED, PROMPT_CHANGED, RUBRIC_CHANGED, TOOL_MANIFEST_CHANGED, ENVIRONMENT_CHANGED, EVIDENCE_AVAILABILITY_CHANGED, NON_DETERMINISTIC_DRIFT, NO_BASELINE, UNKNOWN_DRIFT. Cross-skill changes are hash co-occurrence only.

Ordinary promotion requires a green daily-stats record for every configured day (default seven) and zero bypasses. --force is an explicit override. Auto-promotion uses the same readiness criteria.

## Sources

- v2 architecture, schemas, gate predicate, migration plan, and dogfood report: docs/EVAL_HARNESS_V2.md
- ECC source snapshot, audit, and comparison: docs/ECC_RESEARCH.md
- Skill-design review is separate: standards/skill-quality-v1.md
