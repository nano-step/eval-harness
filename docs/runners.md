# Runners

> Pluggable adapters for behavior-regression testing agents built on any framework.

## What is a runner?

A **runner** is a pluggable adapter that lets the eval-harness regression-test
agents built on any framework, not just opencode. The case YAML, typed checks
and 4-class attribution stay shared — the spawn layer varies.

The source tree includes these runners:

- **`opencode`** — the implicit default.
- **`omp`**, **`claude-code`**, **`codex`** — native, locally authenticated
  coding-agent CLIs. Install and authenticate each CLI independently.
- **`langgraph-node`** — Python-based LangGraph graphs.
- **`atd-sandbox`** — confined base/candidate test execution; not an agent.

Other agents can be connected with a trusted custom runner. This is an
integration contract, not a claim that every agent is supported out of the box.

## The contract

Every runner implements four subcommands. The full authoritative definitions
live in [`scripts/eval/lib/runner.sh`](../scripts/eval/lib/runner.sh); the
table below is the contract surface.

| Subcommand    | Signature                                                  | Purpose                                                                                  | Exit codes            |
| ------------- | ---------------------------------------------------------- | ---------------------------------------------------------------------------------------- | --------------------- |
| `prepare`     | `prepare <workdir> <config_json>`                    | Stage the workdir before `spawn`. | 0 ok, non-zero error |
| `spawn`       | `spawn <workdir> <config_json> <transcript> <prompt>` | Run the agent; write a JSONL transcript and any outputs. | 0 ok, non-zero error |
| `fingerprint` | `fingerprint <workdir> <config_json>`                | Identify the agent definition when known. | 0 ok; stdout = fingerprint |
| `teardown`    | `teardown <workdir> <config_json>`                   | Clean up after execution; idempotent and best-effort. | 0 ok, non-zero warning |

The dispatcher invokes adapter scripts via Bash. OpenCode and LangGraph retain
their existing specialized invocation paths. A case-declared `runner:` must
match an explicit `--runner` or `EVAL_RUNNER` selection; a mismatch is an
error, not a skipped passing case.

## Authoring a custom runner

Set `EVAL_RUNNERS_DIR` to a directory of **trusted** adapter scripts and select
one with `--runner=<name>` or a case's `runner:`. The name must start with a
letter or digit and contain only letters, digits, `.`, `_`, or `-`; `..` and
path separators are rejected. The adapter is `EVAL_RUNNERS_DIR/<name>.sh` and
is invoked with Bash. This directory takes precedence over shipped adapters;
shipped names remain available when no override exists. A CLI-selected runner
also applies when a case does not declare one.

Implement `prepare`, `spawn`, `fingerprint`, and `teardown` using the signatures
above. `spawn` must write JSONL transcript evidence and return nonzero on
failure. Adapters run as trusted host code with the caller's environment and
permissions; the harness does not sandbox them. Never use an untrusted adapter.
The `omp`, `claude-code`, and `codex` adapters are examples.

## Native coding-agent CLIs

Select `--runner=omp`, `--runner=claude-code`, or `--runner=codex`; alternatively
set the case's `runner:`. Each CLI needs its own installation and login. The
case's `prompt` is passed through stdin, and stdout is captured as one JSONL
result event. The case-level `model` or `runner_config.model` may select a
model; A/B overrides and case-level model take precedence over
`runner_config.model`. If none is specified, the CLI chooses its own default.
Token usage and cost are unavailable unless independently measured; they are
not inferred from text output.

These CLIs run as the current user with their native credentials, settings and
tool permissions. Only run trusted agents and cases; a working directory is not
a security sandbox. The adapters do not enable automatic approval or bypass a
CLI's safety controls. Codex is requested to use `workspace-write`. CLI-specific
skill loading, plugins, tools, model names and provider support remain the
responsibility of the selected CLI.

## The `langgraph-node` runner

LangGraph-specific notes for the [`langgraph-node` adapter](../scripts/eval/runners/langgraph-node.sh):

- **Invocation shape:** `python3 -m <module> --input <input.json> --output <output.json>`.
  The harness's `runner_config.module` and `runner_config.input` /
  `runner_config.output` map directly to these argv slots. The module
  MUST expose a callable matching `runner_config.entry_point`
  (`module.py:symbol`).

- **Transcript shape:** The spawn subcommand emits `transcript.jsonl`
  in the same shape as `opencode run --format json` — one event per
  line, with `event`, `type`, `content`, and optional `usage` and `ts`
  keys. `lib/score.sh` consumes this shape unchanged; the
  `output_contains` check kind does a substring match against the
  concatenated `content` fields.

- **Manifest fields:** For each run, `lib/manifest.sh` captures three
  optional fields when `EVAL_RUNNER=langgraph-node`:

  - `graph_fingerprint` — hash of the graph's source code, computed by
    the `fingerprint` subcommand.
  - `langgraph_version` — `python3 -c "import langgraph;
    print(langgraph.__version__)"` with a `none` fallback if langgraph
    is not installed.
  - `python_version` — `python3 --version` first line, with a `none`
    fallback.

- **Venv caching knobs:**

  - `EVAL_VENV_DIR` — override the venv location (default: `<workdir>/.venv`).
  - `EVAL_VENV_CACHE=0` — disable venv caching; always create a fresh venv.
  - `EVAL_SKIP_VENV_PREPARE=1` — skip the `pip install` step entirely
    (use when the venv is pre-populated by an out-of-band step).

- **Known fingerprint limitations:** The `langgraph_node_fingerprint`
  heuristic relies on `@tool` decorator adjacency and a `tools/*.py`
  glob. Multi-line decorators, class-based tools, and conditional tool
  definitions (inside `if __name__ == '__main__':` blocks) are not
  detected and may produce false negatives. Authors of non-trivial
  graphs should verify the fingerprint manually with
  `bash scripts/eval/runners/langgraph-node.sh fingerprint <workdir> <config>`.

## Case YAML extensions

Two new optional top-level fields:

- **`runner:`** — a string naming the active runner (e.g. `langgraph-node`).
  If absent, uses the invocation's `--runner` or `EVAL_RUNNER`, then defaults to
  `opencode`. A conflict with an explicit invocation selection is an error.

- **`runner_config:`** — a free-form object the active adapter reads. The
  opencode runner ignores it. For `langgraph-node` the documented keys are:
  - `entry_point` — `module.py:symbol` (the callable to invoke).
  - `module` — module name (also the .py file in the workdir).
  - `input` — input JSON path (relative to workdir).
  - `output` — output JSON path (relative to workdir).

  Native CLI adapters accept only the optional `model` key; custom adapters
  define their own configuration.

For the full case-YAML reference, see the [README's "Authoring a case"
section](../README.md#authoring-a-case).

## Manifest & attribution

`lib/manifest.sh` captures per-run environment state into
`env-manifest.json`. The schema is `schema_version: 2`; new optional
fields default to `"none"` when not applicable so existing readers
see no change.

For LangGraph runs, three new optional fields appear:

| Field               | Source                                       | Default if missing |
| ------------------- | -------------------------------------------- | ------------------ |
| `graph_fingerprint` | `runner.fingerprint` subcommand output       | `"none"`           |
| `langgraph_version` | `python3 -c 'import langgraph; print(...)'`  | `"none"`           |
| `python_version`    | `python3 --version`                          | `"none"`           |

`lib/attribute.sh` maps `env_delta.keys_changed` to one of four
classes. The regex extensions added for LangGraph are:

- **`SKILL_CHANGED`** — `(skill_bundle_sha|skill_sha|graph_fingerprint)`
- **`MODEL_CHANGED`** — `(model_id|opencode_version|langgraph_version)`
- **`FIXTURE_STALE`** — `fixture_sha` (unchanged)
- **`UNKNOWN_DRIFT`** — fallback when no class matches (e.g. a
  `python_version`-only change). `python_version` is intentionally
  not classified to avoid false positives from routine Python
  upgrades on CI.

The full attribution decision tree is in
[`scripts/eval/lib/attribute.sh`](../scripts/eval/lib/attribute.sh).

## The `atd-sandbox` runner

[`runners/atd-sandbox.sh`](../scripts/eval/runners/atd-sandbox.sh) executes
the same untrusted candidate test in separately exported Git revisions. It does
not start an agent. Its transcript records execution evidence, while the
`discovery_finding` and optional `discovery_test_health` checks consume signed
structured artifacts.

Configuration identifies an absolute `repository`, full 40-hex `baseCommit` and
`candidateCommit`, and case-relative input paths `candidateFile`, `testsDir`
and `specFile` (defaults: `candidate.json`, `tests`, `SPEC.md`). `testsDir`
only locates host inputs. `testsRel` selects their placement inside each exported
revision: default `"."` means the revision root; `"tests"` places them below
`/work/tests`. `candidate.testFile` is relative to that placement root. Generated
cases explicitly use `"."`, preserving imports from `test/foo.test.ts` to
`../src/...`. Other placements must be safe relative directories; traversal,
dependency/VCS paths and collisions with tracked files are refused.
Optional `dependencies` is an external trusted snapshot; `image`, `seed` and
`timeoutSeconds` are bounded by trusted policy. Unknown configuration keys are
rejected. The candidate manifest selects `node:test` or Vitest and binds the
test source hash.

`prepare` checks the daemon, image and effective confinement. `spawn` clears
stale outputs before running; failures cannot fall back to the host. Every
stability sample gets new execution IDs and fresh containers. `fingerprint`
binds runner/policy/configuration; `teardown` removes containers owned by the
workdir. Invalid configuration or infrastructure exits 13 without usable
transcript evidence.

See [Autonomous Test Discovery](./AUTONOMOUS_TEST_DISCOVERY.md) for dependency
setup, attestation/review trust, outcome semantics, limits and the live pilot.

## Examples

- [`examples/langgraph-runner/`](../examples/langgraph-runner/) — the
  canonical LangGraph example with three cases:
  - [`shell-basic.yaml`](../examples/langgraph-runner/cases/shell-basic.yaml) —
    basic file + shell checks; uses `expect_min: 1` with `grep -c`.
  - [`jq-path-contains.yaml`](../examples/langgraph-runner/cases/jq-path-contains.yaml) —
    checks the output JSON's `sources` array contains
    `langgraph-docs`. Note the array-constructor path
    (`[.sources[]] | unique`) for jq 1.8.1 compatibility.
  - [`output-contains.yaml`](../examples/langgraph-runner/cases/output-contains.yaml) —
    transcript substring check on the graph's print output.

## Status

- **Shipped** (v0.5.0):
  - `opencode` — implicit default; no adapter file.
  - `langgraph-node` — first explicit adapter; LangGraph framework.

- **Unreleased source additions**:
  - `omp`, `claude-code`, `codex` — native CLI adapters.
  - Trusted external adapters via `EVAL_RUNNERS_DIR`.
  - `atd-sandbox` — confined differential test execution; see the discovery guide.

- **Proposed** (not yet shipped):
  - `python-generic` — Python agents not built on LangGraph.
  - `http` — agents reached over HTTP (any framework with a JSON API).
  - `mcp` — Model Context Protocol agents reached over stdio or HTTP.
