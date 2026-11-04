# Collision discovery pilot fixture

A self-contained benchmark for Autonomous Test Discovery, **modelled on** axis-aligned rectangle
collision as used by 2D canvas tooling. It is not part of, and does not claim to represent, the
`img2pixi2d` plugin, which has no collision implementation. Nothing here is deployed anywhere.

| Path | Purpose |
| --- | --- |
| `SPEC.md` | The contract: touching edges and corners are not overlap, zero-size rectangles never overlap, negative coordinates are valid, symmetric and translation invariant, flush movement does not collide. |
| `src/collision.ts` | The code under test (`overlaps`, `translate`, `collidesAfterMove`). |
| `test/collision.test.ts` | The **existing** baseline tests. They have no dedicated touching-edge, flush-movement or zero-size-second-rectangle case. Whether that leaves a mutation gap is measured by the pilot (Stryker scoped to the changed functions), not assumed: the fast-check properties may already kill some of those mutants. |
| `patches/clean-change.patch` | A behaviour-preserving refactor. A sound pipeline must not report it as a defect. |
| `patches/boundary-defect.patch` | Injected defect: edges that only touch along the x axis count as overlap. The baseline tests still pass on it. |
| `patches/zero-size-defect.patch` | Injected defect: the emptiness check of the second rectangle is dropped. The baseline tests still pass on it. |
| `build-fixture-repo.sh` | Creates an isolated git repository with the baseline commit and one branch per revision. Never installs or runs anything. |
| `package.json`, `package-lock.json` | Pinned fixture-only dependencies: Vitest 5.1.0, fast-check 4.10.2, StrykerJS core and vitest-runner 10.1.1. They are never installed by the harness; `scripts/eval/discovery/setup-deps.sh` builds a read-only dependency snapshot (`npm ci --ignore-scripts`) as an explicit, separate, trusted step. |
| `config/` | Controlled invocation examples as fixture data: a materialized skill case, the QA Factory oracle hook registration, request and adapter configuration, the Jev gate test command, and an operator expectation-review record. `@@NAME@@` tokens are filled in by `scripts/eval/discovery/pilot.sh`. |

Generated tests are never run on the host: the pilot executes them only through the `atd-sandbox`
runner (Docker, no network, read-only source and dependencies).

The pilot's generated tests come from a real model call through the pipeline
(`scripts/eval/discovery/run.mjs`); this directory contains no pre-written discovery tests.
