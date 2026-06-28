# eval-harness vs other LLM eval tools

Honest comparison of eval-harness against the four tools you're most likely to pick up instead. This page is maintained — open a PR if you spot something wrong or a tool moved on.

> **TL;DR.** If you need a broad LLM-eval framework with assertions, web UI, dataset management, and a Python SDK, use **promptfoo**. If you want **behavior-regression detection with attribution, flaky tagging, $-cost gating, and a 6-field FAIL schema**, use eval-harness. They compose — many teams run both.

## Comparison table

| Capability | eval-harness | promptfoo | DeepEval | Ragas | OpenAI Evals |
|---|---|---|---|---|---|
| **Primary job** | Behavior-regression | General LLM eval | LLM unit testing | RAG eval | Reference eval framework |
| **License** | MIT | MIT | Apache 2.0 | Apache 2.0 | MIT |
| **Runtime** | Bash + jq + python3 stdlib | Node | Python | Python | Python |
| **Daemon?** | No | No (CLI + optional server) | No | No | No |
| **Web UI** | No (planned v0.9) | Yes | Yes | No | No |
| **Determ. check kinds shipped** | 5 (shell, jq_path_contains, file_exists, output_contains, output_not_contains) | 30+ assertions | ~15 metrics | ~10 RAG metrics | extensible |
| **LLM-judge** | Yes (1 kind, 3-sample majority, returns `verdict: null` honestly) | Yes (llm-rubric, model-graded-closedqa) | Yes (G-Eval, custom metrics) | Yes (faithfulness, answer-relevance) | Yes (model_graded_qa) |
| **4-class failure attribution** | **✅ Yes** (skill/fixture/model/unknown) | No | No | No | No |
| **6-field FAIL schema with env_delta** | **✅ Yes** | Partial (expected/actual only) | Partial | Partial | Partial |
| **3-sample byte-identical stability check** | **✅ Yes** (flaky tag) | No | Manual retry | No | No |
| **$-cost gating with hard ceiling** | **✅ Yes** (`EVAL_BUDGET_USD`) | Cost tracked, not gated | Tracked | No | Tracked |
| **Auto-fix proposals on FAIL** | **✅ Yes** (proposed, not auto-applied) | No | No | No | No |
| **Git pre-push hook out of the box** | **✅ Yes** | Manual | Manual | Manual | Manual |
| **Per-repo opt-in registry (multi-repo workspaces)** | **✅ Yes** | No | No | No | No |
| **Dataset / scenario library** | No | Yes (huge) | Yes | Yes (HotpotQA, etc.) | Yes |
| **CI integrations** | Bash exit codes (JUnit/SARIF on roadmap) | JUnit, GitHub Annotation, JSON | pytest, JUnit | pytest | JSON output |
| **Provider coverage** | Anthropic (via opencode); model-agnostic checks | 50+ via providers | 20+ | LangChain ecosystem | OpenAI-first |
| **Best for** | Regression on an agent you ship to prod | General eval workflows | Unit-test-style metrics on individual LLM calls | RAG quality benchmarks | OpenAI ecosystem |

## Where each tool wins

### promptfoo wins

- **Scenario coverage.** Dataset management, redteaming, benchmark suites, prompt comparison matrices.
- **Provider matrix.** 50+ providers including Bedrock, Replicate, HuggingFace local, etc.
- **Web UI for inspection.** Great for non-engineers reviewing results.
- **Massive community.** ~5k stars, active Discord, fast issue turnaround.

If you're picking your first LLM eval tool with no specific regression-detection requirement, **start with promptfoo**.

### DeepEval wins

- **pytest integration.** If your team already lives in pytest, the ergonomics fit instantly.
- **Custom metrics.** G-Eval lets you build your own metric in 5 lines.
- **Confident AI cloud.** Hosted dashboard if you want managed eval.

### Ragas wins

- **RAG-specific metrics.** Faithfulness, answer-relevance, context-precision — these are not generic LLM checks, they're RAG-specific math.
- **LangChain ecosystem fit.**

### OpenAI Evals wins

- **Reference implementation.** The most-cited eval framework in academic LLM literature.
- **Eval as a community contribution model.** They review and merge community-submitted evals.

### eval-harness wins

- **Attribution.** No other tool tells you `SKILL_CHANGED` vs `MODEL_CHANGED` vs `FIXTURE_STALE`. This is the single biggest time-save when a test fails on a Tuesday morning.
- **Honest flaky tagging.** Re-run-until-pass is the default fix elsewhere. We re-run 3× **and tell you** when it diverged.
- **6-field FAIL with `env_delta`.** Most tools give you `expected` and `actual`. We give you four more fields specifically chosen to skip 80% of the "where did this come from" debugging.
- **$-cost ceiling.** Hard cap, hard exit, no surprises on your Anthropic invoice.
- **Pre-publish + pre-push gates already wired up.** Other tools require you to write the CI integration. We ship the hooks.
- **Honesty about scope.** We don't claim to be a quality grader. We don't claim to score "prompt engineering goodness." We measure regression. That's it. ([scope statement in README](../README.md#scope-statement)).

## When to use both

It's a real pattern. Run promptfoo for **scenario coverage** during development (does my prompt handle 200 redteam inputs?) and eval-harness for **regression gating** in CI (did this push break what worked last week?). They use different config files, different runners, and they don't fight.

If you do this, set `promptfoo eval --output=promptfoo-results.json` and add an eval-harness case that reads that JSON via `kind: jq_path_contains` to gate on a minimum pass rate. Cross-tool composition.

## What we don't do (and have no plans to)

- **Prompt comparison matrices.** Use promptfoo.
- **Dataset management.** Use a real data tool.
- **Redteam scenario libraries.** Use [promptfoo redteam](https://www.promptfoo.dev/docs/red-team/) or [Anthropic's redteaming](https://www.anthropic.com/news/many-shot-jailbreaking).
- **Hosted SaaS / cloud dashboard.** We're MIT and local-only on purpose. Local-first matches the regression-gating use case.
- **Replacing your unit test framework.** eval-harness gates _LLM_ behavior. Your code still needs jest/pytest/cargo.

## Honest weaknesses of eval-harness today

We try to be honest about gaps so you can make a real decision:

- **One runner shipped (opencode).** LangGraph and Claude-Agent-SDK runners are roadmap (v0.8.0). If you need LangGraph today, this is not your tool yet.
- **No web UI.** `eval-harness serve` is roadmap v0.9. Inspection today is `cat runs/*/diff.md`.
- **Bash + jq.** If your team can't ship bash to CI, this isn't your tool. (See the [GitHub Action](../.github/actions/eval-harness/action.yml) for a path around that.)
- **CSV/JUnit/SARIF output not shipped yet.** Issue [#11](https://github.com/nano-step/eval-harness/issues/11).
- **No `pass@k` mode yet.** Issue [#21](https://github.com/nano-step/eval-harness/issues/21).
- **Only ~4 weeks of public history.** v0.1 was 2026-05-04. We're young. Things move.

If any of these gaps is a blocker, use promptfoo or DeepEval today and watch the eval-harness roadmap. Or — better — open an issue and tell us what you need. The roadmap responds to real users.
