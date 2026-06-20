# Runners

> Pluggable adapters for behavior-regression testing agents built on any framework.

## What is a runner?

A **runner** is a pluggable adapter that lets the eval-harness regression-test
agents built on any framework, not just opencode. The case YAML, the 6 check
kinds, and the 4-class attribution stay unchanged — only the spawn layer varies.

The harness ships with two runners:

- **`opencode`** — the implicit default; the original agent. No adapter file
  exists for it; the dispatcher has a fast-path that calls the existing
  `spawn_opencode`, `token_total`, and preflight probes directly.
- **`langgraph-node`** — the first explicit adapter, added in v0.5.0. Runs
  Python-based LangGraph graphs via `python3 -m <module> --input X --output Y`.

Future runners (Python generic, HTTP, MCP) are proposed but not yet shipped.

## The contract

Every runner implements four subcommands. The full authoritative definitions
live in [`scripts/eval/lib/runner.sh`](../scripts/eval/lib/runner.sh); the
table below is the contract surface.

| Subcommand    | Signature                                                  | Purpose                                                                                  | Exit codes            |
| ------------- | ---------------------------------------------------------- | ---------------------------------------------------------------------------------------- | --------------------- |
| `prepare`     | `<name>_prepare <workdir> <config_json>`                   | Stage the workdir (e.g. materialize fixtures, build a venv) before `spawn`.              | 0 ok, non-zero error  |
| `spawn`       | `<name>_spawn <workdir> <config_json> <transcript> [prompt]` | Run the agent; write a `transcript.jsonl` and any outputs.                             | 0 ok, non-zero error  |
| `fingerprint` | `<name>_fingerprint <workdir> <config_json>`               | Compute a hash of the graph / agent definition for attribution (skips outputs).          | 0 ok; stdout = hash    |
| `teardown`    | `<name>_teardown <workdir> <config_json>`                  | Clean up after `spawn` (e.g. drop the venv, remove temp files). Idempotent and best-effort. | 0 ok, non-zero warn |

The dispatcher routes each subcommand to the runner's function via
`dispatch_runner <name> <subcommand> <args...>`. `run.sh` calls the
dispatcher for the runner selected by the active invocation (CLI flag or
case YAML default). The case YAML's `runner:` field is a required-to-match
guard: if it differs from the active runner, the case is skipped (one-line
notice on stderr, exit 0 for the case).

## Authoring a new runner

Step-by-step:

1. **Create** `scripts/eval/runners/<name>.sh`. The filename MUST match the
   `runner:` value the case YAMLs will use.

2. **Implement the four subcommand functions** (`<name>_prepare`,
   `<name>_spawn`, `<name>_fingerprint`, `<name>_teardown`) as bash
   functions in the file. Follow the signatures above. Each function
   MUST be `export -f`-ed so `dispatch_runner` can find it after the
   adapter is sourced.

3. **Register the runner** at the bottom of the adapter file with
   `register_runner <name> "$BASH_SOURCE"`. This adds `<name>` to
   `runner_names` and exposes the four subcommands through
   `dispatch_runner`.

4. **Source the adapter** from `scripts/eval/run.sh` (or have it
   auto-discovered under `scripts/eval/runners/`). The langgraph-node
   adapter is sourced unconditionally; future adapters can do the same
   or be added behind a feature flag.

5. **Write a test** at `scripts/eval/tests/runner_<name>.sh`. Use the
   existing [`runner_langgraph.sh`](../scripts/eval/tests/runner_langgraph.sh)
   as a template — it stages fixtures, stubs the underlying toolchain,
   and verifies the four subcommand traces plus attribution behaviors.

6. **Add an example** under `examples/<name>-runner/` with at least one
   case YAML so the integration test has a real fixture to point at.
   See [`examples/langgraph-runner/`](../examples/langgraph-runner/) for
   the canonical layout: 3 cases covering the three check patterns
   (file/shell, jq-path-contains, output-contains).

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
  Defaults to `opencode` if absent. Acts as a required-to-match guard: if
  the case's `runner:` differs from `run.sh`'s `--runner=<name>` (or the
  default), the case is skipped with a one-line notice.

- **`runner_config:`** — a free-form object the active adapter reads. The
  opencode runner ignores it. For `langgraph-node` the documented keys are:
  - `entry_point` — `module.py:symbol` (the callable to invoke).
  - `module` — module name (also the .py file in the workdir).
  - `input` — input JSON path (relative to workdir).
  - `output` — output JSON path (relative to workdir).

  Authors may add runner-specific keys; the schema is intentionally open.

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

- **Proposed** (not yet shipped):
  - `python-generic` — Python agents not built on LangGraph.
  - `http` — agents reached over HTTP (any framework with a JSON API).
  - `mcp` — Model Context Protocol agents reached over stdio or HTTP.

A new adapter is a self-contained `scripts/eval/runners/<name>.sh` plus
a `scripts/eval/tests/runner_<name>.sh` plus an
`examples/<name>-runner/` directory. No core harness changes required
when the contract is honored.
