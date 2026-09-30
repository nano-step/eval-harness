# @nano-step/eval-harness

[![Latest release](https://img.shields.io/github/v/release/nano-step/eval-harness)](https://github.com/nano-step/eval-harness/releases/latest)
[![Tests](https://github.com/nano-step/eval-harness/actions/workflows/tests.yml/badge.svg?branch=main)](https://github.com/nano-step/eval-harness/actions/workflows/tests.yml)
[![License](https://img.shields.io/github/license/nano-step/eval-harness)](./LICENSE)

**v0.5.0 · released 2026-09-30**

Typed evaluation for OpenCode skills and AI-agent workflows. Run a skill with OpenCode, or grade content-addressed evidence from another runner without starting a model. Results preserve behavior status, product dimensions, evidence availability, and provenance instead of flattening them into one score.

## What it does

- **Capability, regression, and product evaluations.** Each case declares what it measures and whether it compares against a baseline.
- **Typed outcomes.** `PASS`, `FAIL`, `ERROR`, `NEEDS_REVIEW`, and `INDETERMINATE` stay distinct. Missing evidence is never a pass or a measured zero.
- **Provider-neutral grading.** `grade` validates a schema-1 manifest binding the case, workdir tree, transcript, artifacts, environment, and provenance. It does not execute a model or load arbitrary evaluator plugins.
- **Independent product dimensions.** Numeric measurements stay grouped by their declared dimension; eval-harness does not compute a global product-quality score.
- **Auditable comparisons and reports.** Baselines, typed A/B results, attribution, token/cost/duration coverage, JUnit XML, and SARIF help explain what changed and what evidence is available.

`run` is the OpenCode execution adapter. A LangGraph runner example demonstrates the runner contract; `grade` accepts prepared evidence without coupling the grader to that runner.

## Install

The package is distributed from GitHub; it is **not published to the npm registry**. Install the checked-out source and link its CLI:

```bash
git clone https://github.com/nano-step/eval-harness.git
cd eval-harness
npm link
eval-harness --version
```

Node.js 18+ is required for the CLI link. Running `npm link` creates a local symlink to this checkout; it does not publish a package.

## Quick start

Set `OPENCODE_SKILLS_ROOT` to the directory containing `<skill-name>/evals/cases/*.yaml`, then run:

```bash
export OPENCODE_SKILLS_ROOT="/path/to/skills-root"

eval-harness run --skill=my-skill --dry-run
eval-harness run --skill=my-skill
```

Use `--dry-run` to check discovery and preflight without spawning an evaluation. After reviewing a passing run, record a baseline and enable strict gates:

```bash
eval-harness baseline --skill=my-skill
eval-harness run --skill=my-skill --strict
```

Provider-neutral grading uses a deterministic evidence bundle and manifest:

```bash
eval-harness grade --manifest=grading-manifest.json --strict
```

Strict grading exits 13 for malformed or tampered evidence, 14 for `FAIL`, 15 for pending human review, and 16 for indeterminate evidence. The grader never starts a model.

## Evaluation types and check kinds

| Type | Use | Baseline comparison |
|---|---|---|
| `regression` | Preserve an existing behavior contract | Enabled by default |
| `capability` | Verify declared behavior or coverage | Disabled by default |
| `product` | Report named product measurements | Disabled by default |

Shipped checks: `shell`, `jq_path_contains`, `file_exists`, `output_contains`, `output_not_contains`, `llm_judge`, `metric_score`, `trajectory`, and `human_review`. Required checks determine the typed result; optional checks report evidence without gating. Product dimensions remain separate.

For prose checks, `llm_judge` requires `ANTHROPIC_API_KEY`; abstentions or unresolved votes remain unavailable rather than becoming a synthetic pass. Deterministic checks and `grade` do not require a model.

## Reliability, resources, and attribution

- Repeated trials report pass@k, pass^k, and Wilson bounds for the same case/configuration. The IID assumption is explicit, not measured.
- Token, cost, and duration fields carry measured/partial/unavailable coverage. Unknown cost remains `null`; with `EVAL_BUDGET_USD` enabled, unmeasured ledger spend blocks later gated runs until reconciled.
- Attribution reports changed evidence and environment fields. Hash co-occurrence is not proof that a change caused an outcome.
- `eval-harness ab` compares two skills and can warn on cost increases; its cost threshold is warning-only.
- `eval-harness metaeval` runs an offline stub corpus and reports harness validity separately from skill results.

## Shell-check safety

**v0.5.0 includes a documented 0.x breaking change.** By default, `kind: shell` accepts a constrained, shell-free `jq`/`printf`/`wc -l` language; jq input files must resolve inside the case workdir. Other shell commands must migrate to a typed grader or opt in with `unsafe_shell: true` (or `EVAL_ALLOW_UNSAFE_SHELL=1`) only when the case YAML is trusted. The opt-in runs with the harness user's permissions; the workdir is not an OS sandbox.

## Tests and reports

Run the deterministic offline suite with:

```bash
npm test
```

The suite uses fixtures and stub runners; it does not measure live model quality, latency, or cost. Optional exports are available with `--report=junit:<path>` and `--report=sarif:<path>`.

## Documentation

- [Documentation index](./docs/README.md)
- [v0.5.0 design and migration contract](./docs/EVAL_HARNESS_V2.md)
- [Runner contract](./docs/runners.md) and [LangGraph example](./examples/langgraph-runner/)
- [Janus benchmark](./docs/JANUS_BENCHMARK.md): offline evidence and the no-go decision on a native adapter
- [Security policy](./SECURITY.md), [versioning policy](./POLICY.md), and [known issues](./KNOWN_ISSUES.md)
- [Changelog](./CHANGELOG.md) and [contributing guide](./CONTRIBUTING.md)

## Scope

eval-harness measures declared behavior and product evidence. It does not review skill-design quality, infer causality from hashes, or replace application unit tests. JUnit/SARIF reports are local outputs; the project has no hosted results service. See the [Janus benchmark](./docs/JANUS_BENCHMARK.md) for why its experimental evaluator is not currently used as a native execution adapter.

MIT · [nano-step](https://github.com/nano-step)
