# Janus-to-eval-harness benchmark

**Date:** 2026-09-29  
**Janus source:** 8263585 (package v0.1.10)  
**Environment:** macOS arm64, Rust 1.97.1  
**Mode:** local deterministic stub; no live model/API calls, token spend, or paid latency measurement.

## Question

Can Janus's experimental eval feature currently run a candidate and produce evidence suitable for using it as an eval-harness runner?

## Method

Built Janus with `cargo build -p harness-cli --features eval` and ran `cargo test -p harness-cli --features eval`. Then ran the built CLI and eval-harness against the same temporary skill directory and two case-v2 fixtures, with the same `opencode` stub. The stub writes `output.txt` and records whether an actual invocation occurred.

The two cases were:

1. A positive `file_exists(output.txt)` case, which passes only if the candidate executor is invoked.
2. A case with an empty `checks: []` list, to test fail-closed configuration handling.

## Results

| Measurement | Janus `0.1.10`, `--features eval` | eval-harness `v0.5.0` |
|---|---:|---:|
| Positive file-generation case | FAIL; summary REGRESSION | PASS |
| Stub executor invoked | No | Yes |
| Empty-check case | PASS with 0 checks | ERROR |
| Live model calls / token cost | 0 / $0 | 0 / $0 |
| Rust eval-feature tests | 66 passed | — |
| Local shell suites | — | 58 passed |

The Janus result directory confirmed `CaseResult.passed=false` for the positive case and `CaseResult.passed=true,total=0` for the empty-check case. The OpenCode stub marker remained absent after the Janus run and was written by the eval-harness run.

## Diagnosis

- In `crates/harness-cli/src/interface.rs::run_eval`, the run path creates the workdir and copies fixtures, then calls `run_all_checks`. It does not call `eval::spawn::spawn_opencode`. A scoped source check found no `spawn_opencode`/`SpawnConfig` call in `interface.rs`; the runtime stub test independently confirmed that no candidate execution occurred.
- `crates/harness-cli/src/eval/scoring.rs::run_all_checks` marks a case passed when zero checks fail, including an empty check list. The same fixture is ERROR under eval-harness, which rejects empty grader sets.
- `crates/harness-cli/src/eval/stats.rs::build_run_summary` counts every failed case as a regression; the tested Janus run had no baseline, yet its verdict was `REGRESSION`.
- The 66 passing Rust tests did not catch these CLI run-path defects. Janus declares the eval feature experimental and its module allows dead code; unit-suite success alone is not evidence of candidate execution.

## Decision

**No-go for a Janus execution adapter or a claim that Janus is ready as an eval runner.** Fix and test Janus candidate invocation, empty-check rejection, and baseline-aware regression semantics first. The eval-harness `grade` contract remains a viable future bridge once Janus exports real, content-addressed candidate evidence.

This benchmark is a deterministic integration/contract check, not a quality comparison between agent models. No live model behavior, reliability distribution, cost, or end-to-end latency was measured.
