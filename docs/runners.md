# Runners

> **Status (v0.4.2):** one runner ships — `opencode-skill`. The runner abstraction described here is the seam everything else is built around. LangGraph and Claude-Agent-SDK runners are tracked roadmap items.

## What is a runner?

A **runner** adapts eval-harness's core to a specific agent framework. The core handles:

- baseline + diff
- 4-class attribution
- 6-field FAIL schema
- 3-sample stability check
- $-cost gating
- pre-push / pre-publish hooks
- transcript scoring (all 6 check kinds)

A runner handles:

- **how to spawn the agent under test** with a given prompt, fixture directory, and env
- **how to capture the agent's transcript** (stdout, structured log, OTel trace — runner's choice)
- **how to compute the `skill_sha` / `agent_sha`** that feeds attribution

That's it. Three responsibilities. Everything else is shared.

## Runner contract

A runner is a script (or any executable) at `scripts/eval/runners/<name>.sh` that responds to four subcommands:

```bash
runners/<name>.sh prepare    <case_yaml> <workdir>
runners/<name>.sh spawn      <case_yaml> <workdir> <transcript_out>
runners/<name>.sh fingerprint <case_yaml>             # → stdout: SHA of the agent under test
runners/<name>.sh teardown   <workdir>                # optional, runs on exit
```

The core invokes them in order: `prepare` → `spawn` → (score) → `teardown`. The runner is allowed to fail any of them; the core treats non-zero exit as a harness error (not a case FAIL — see [`tests/transcript_empty_guard.sh`](../scripts/eval/tests/transcript_empty_guard.sh) for the distinction).

The transcript file written by `spawn` is the **single source of truth** for scoring. The 6 check kinds read it via the [`score.sh`](../scripts/eval/lib/score.sh) library, runner-agnostic.

## Why this abstraction matters

Without runners, eval-harness is "opencode skill testing." With runners, it's "any LLM-agent regression testing where you can:

1. Reproducibly invoke the agent with a prompt + fixture
2. Capture its transcript
3. Hash its agent definition"

That bar is low. **Every framework I've checked clears it.**

## Shipped runners

### `opencode-skill` (v0.1.0+, default)

- Reads skills from `OPENCODE_SKILLS_ROOT` (env > walk-up > user-global)
- `spawn` invokes `opencode run` with `skills_loaded` pinned
- `fingerprint` = transitive SHA over the skill bundle (so cross-skill effects show up in attribution)
- Captures transcript via `opencode --json-log`

Implementation lives in [`scripts/eval/lib/spawn.sh`](../scripts/eval/lib/spawn.sh) + [`scripts/eval/lib/manifest.sh`](../scripts/eval/lib/manifest.sh). It pre-dates the formal runner contract; it's being moved to `scripts/eval/runners/opencode-skill.sh` as part of v0.8.0.

## Roadmap runners

### `langgraph-node` (v0.8.0 — [issue #to-be-filed])

Adapts a LangGraph node or full graph to eval-harness.

- `prepare`: install the case's Python deps in an ephemeral venv
- `spawn`: invoke `python -m <module>` with the case prompt routed to the graph's entry node, transcript captured via LangSmith local-export or `langgraph.utils.tracer`
- `fingerprint`: SHA over the graph definition module + its prompt templates + any `@tool`-decorated functions

If you want to help build this runner: the issue (when filed) will be tagged `help wanted, runner`. Comment on [discussion #28](https://github.com/nano-step/eval-harness/discussions/28) in the meantime.

### `claude-agent-sdk` (v0.9.0)

Adapts the Anthropic [Claude Agent SDK](https://docs.anthropic.com/) to eval-harness.

- `spawn`: invoke the SDK in headless mode with the case prompt
- `fingerprint`: SHA over the agent's system prompt + tools + model_id

### `crewai` (v0.10.0 — maybe)

Only if there's user demand. Open an issue if you want it.

### `bare-anthropic` (v0.10.0)

For regression-testing _just an Anthropic API prompt_ with no agent framework. `spawn` is a direct API call. This is the smallest possible runner — useful as a reference implementation for new runners.

## Build your own runner

The contract is small enough that a working runner is ~150 lines of bash or ~80 lines of Python. If you build one, please open a PR — we'll cohabitate it under `scripts/eval/runners/` with attribution.

Minimum viable example skeleton:

```bash
#!/usr/bin/env bash
# scripts/eval/runners/my-runner.sh
set -euo pipefail

cmd="$1"; shift

case "$cmd" in
  prepare)
    case_yaml="$1"; workdir="$2"
    # set up fixture, deps, ephemeral env
    ;;
  spawn)
    case_yaml="$1"; workdir="$2"; transcript_out="$3"
    # invoke the agent, write its transcript to $transcript_out
    ;;
  fingerprint)
    case_yaml="$1"
    # echo the SHA of the agent under test, e.g. sha256sum of the prompt file
    ;;
  teardown)
    workdir="$1"
    # optional cleanup
    ;;
  *)
    echo "unknown runner cmd: $cmd" >&2; exit 64 ;;
esac
```

Then in your case YAML:

```yaml
runner: my-runner
prompt: |
  ...
checks:
  - kind: output_contains
    needle: "expected substring"
```

## Why opencode-first?

Honest answer: opencode is where the maintainer ([@hoainho](https://github.com/hoainho)) ships agents. Building eval-harness against the framework you actually use is the only way to make sure the abstractions don't lie. The runner contract was extracted **after** opencode-skill worked end-to-end — not before.

This is good engineering ([extract abstractions from working code](https://wiki.c2.com/?RuleOfThree)), not opencode favoritism. The runner contract is friendly to any framework. PRs welcome.
