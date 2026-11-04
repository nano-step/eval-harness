# @nano-step/eval-harness

[![Latest release](https://img.shields.io/github/v/release/nano-step/eval-harness)](https://github.com/nano-step/eval-harness/releases/latest)
[![Tests](https://github.com/nano-step/eval-harness/actions/workflows/tests.yml/badge.svg?branch=main)](https://github.com/nano-step/eval-harness/actions/workflows/tests.yml)
[![License](https://img.shields.io/github/license/nano-step/eval-harness)](./LICENSE)

**v0.5.0 · released 2026-09-30**

**Know whether an agent still does what you expect—and what evidence supports that decision.**

**Turn your harness into a more complete, reliable product—with evidence you can trust.**

eval-harness evaluates OpenCode skills and AI-agent workflows with typed checks, baseline comparisons, and evidence-backed reports. Run an agent through a runner, or grade prepared evidence without starting a model.

## Why eval-harness?

Agent behavior can change when a skill, fixture, model, or environment changes. A plausible response alone cannot tell you whether the behavior still meets its contract. A single score also hides the difference between a failed check, missing evidence, and a decision that needs human review.

Use eval-harness when you need repeatable checks for agent behavior, a baseline to detect regressions, and enough provenance to investigate changes. It complements application tests and general-purpose LLM evaluation tools; it does not replace them or prove that a changed input caused a failure.

## Core features

| Feature | What it does | Why it matters |
|---|---|---|
| **Capability, regression, and product cases** | Define behavior checks and named product dimensions; compare regression cases against a baseline. | Check new capabilities without losing sight of existing behavior, and keep distinct measurements separate. |
| **Typed outcomes** | Report `PASS`, `FAIL`, `ERROR`, `NEEDS_REVIEW`, or `INDETERMINATE`. | Missing evidence is neither a pass nor a measured zero; human review and execution errors stay visible. |
| **Provider-neutral evidence grading** | Validate a schema-1 manifest binding the case, workdir tree, transcript, artifacts, environment, and provenance. | Grade evidence produced by another runner without starting a model or loading arbitrary evaluator plugins. |
| **Baselines and attribution** | Compare results and report changed evidence and environment fields. | Narrow an investigation to observed changes without claiming that hash co-occurrence proves causality. |
| **Reliability and resource reporting** | Report repeated-trial statistics and measured, partial, or unavailable token, cost, and duration coverage. | See variability and unknown costs instead of treating incomplete measurements as zero. |
| **CI-ready reports** | Export JUnit XML and SARIF; use strict result gates. | Bring evaluation outcomes into existing review and CI workflows. |
| **Autonomous Test Discovery** | Generate bounded intent-aware tests, run scoped Stryker mutation and isolated base/candidate execution, then feed findings to the existing graders. | Surface potential gaps for review; discovery gates are warn-only by default, and a generator cannot approve its own findings. |

`run` supports OpenCode (default), OMP, Claude Code, Codex and LangGraph. Trusted custom adapters can connect other agents; `atd-sandbox` executes discovery tests in confined containers. `grade` accepts prepared evidence without coupling grading to the producer.

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

For the default OpenCode runner, install `opencode` on `PATH`, make `yq` or Python 3 available, and configure a provider credential through OpenCode or a supported API key. These preflight requirements also apply to `--dry-run`; it does not spawn an evaluation.

Set `OPENCODE_SKILLS_ROOT` to the directory containing `<skill-name>/evals/cases/*.yaml`, then run:

```bash
export OPENCODE_SKILLS_ROOT="/path/to/skills-root"

eval-harness run --skill=my-skill --dry-run
eval-harness run --skill=my-skill
```

For an installed, authenticated agent CLI, select `--runner=omp`,
`--runner=claude-code`, or `--runner=codex` instead. These agents run with
their native user credentials and permissions, not in a harness security
sandbox. See the [runner guide](./docs/runners.md) for custom adapters and
CLI-specific limitations.

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

Available checks: `shell`, `jq_path_contains`, `file_exists`, `output_contains`, `output_not_contains`, `llm_judge`, `metric_score`, `trajectory`, `human_review`, `discovery_finding` and `discovery_test_health`. Required checks determine the typed result; optional checks report evidence without gating. Product dimensions remain separate. The [discovery guide](./docs/AUTONOMOUS_TEST_DISCOVERY.md) documents the new check/evidence trust boundary.

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

Run the local evaluation suites with:

```bash
npm test
```

The suites use controlled fixtures and stub runners, with live Docker checks when their prerequisites are present; they do not measure live model quality, latency or cost. The separate discovery pilot does. Optional exports are available with `--report=junit:<path>` and `--report=sarif:<path>`.

## Documentation

- [Documentation index](./docs/README.md)
- [v0.5.0 design and migration contract](./docs/EVAL_HARNESS_V2.md)
- [Runner contract](./docs/runners.md) and [LangGraph example](./examples/langgraph-runner/)
- [Autonomous Test Discovery](./docs/AUTONOMOUS_TEST_DISCOVERY.md): operation, sandbox, review/replay and QA Factory/Jev gates
- [Janus benchmark](./docs/JANUS_BENCHMARK.md): offline evidence and the no-go decision on a native adapter
- [Security policy](./SECURITY.md), [versioning policy](./POLICY.md), and [known issues](./KNOWN_ISSUES.md)
- [Changelog](./CHANGELOG.md) and [contributing guide](./CONTRIBUTING.md)

## Scope

eval-harness measures declared behavior and product evidence. It does not review skill-design quality, infer causality from hashes, or replace application unit tests. JUnit/SARIF reports are local outputs; the project has no hosted results service. See the [Janus benchmark](./docs/JANUS_BENCHMARK.md) for why its experimental evaluator is not currently used as a native execution adapter.

MIT · [nano-step](https://github.com/nano-step)
