# Known Issues — eval-harness v0.4.2

This document lists every confirmed bug, gap, and limitation in the currently-shipped code.
Surfaced by two independent audits (explore + oracle) on 2026-05-30. Updated when fixed.

**Read this before relying on eval-harness for production work.**

---

## ✅ BLOCKERs — all 8 closed in v0.4.2

The 8 BLOCKERs documented below were all fixed in v0.4.2 (2026-05-30). The original entries are preserved for history. Each fix landed with a regression test that runs as part of the standard test suite.

---

## ✅ BLOCKERs (closed v0.4.2 — original descriptions preserved for history)

### BLK-1 · `EVAL_BYPASS=1` crashes instead of bypassing
- **File**: [scripts/eval/run.sh:123](./scripts/eval/run.sh)
- **Cause**: `log_bypass` called on line 123, defined on line 169. Under `set -e` this is a "command not found" → exit 127.
- **Symptom**: Setting `EVAL_BYPASS=1` does not bypass the eval; the run crashes and no bypass event is logged.
- **Workaround**: Don't use `EVAL_BYPASS=1`. To skip a skill, remove its `evals/cases/` directory.

### BLK-2 · `score_shell` runs arbitrary YAML-supplied shell with no sanitization
- **File**: [scripts/eval/lib/score.sh:64](./scripts/eval/lib/score.sh)
- **Cause**: `out="$(cd "$workdir" && bash -c "$cmd" 2>&1 || true)"` where `$cmd` comes verbatim from `.cmd` in a case YAML.
- **Symptom**: A case YAML containing `cmd: "rm -rf ~"` would execute it with the harness user's privileges.
- **Workaround**: **Do NOT run cases authored by anyone you don't trust.** Safe for your own skill cases.

### BLK-3 · Fixture-copy loop runs in subshell + lacks `..` path-traversal guard
- **File**: [scripts/eval/run.sh:242](./scripts/eval/run.sh)
- **Cause**: `yq … | jq … | while …` runs body in a subshell (errors invisible); no validation that `dest` paths stay inside `$workdir`.
- **Symptom**: A case YAML with `fixtures: { "../../etc/passwd": "..." }` could write outside the sandbox.
- **Workaround**: Audit case YAMLs you import from third parties before running.

### BLK-4 · `SKILL_CHANGED` attribution silently broken on macOS
- **File**: [scripts/eval/lib/attribute.sh:18](./scripts/eval/lib/attribute.sh)
- **Cause**: `grep -qx "skill_bundle_sha\|skill_sha"` — BRE `\|` not supported by BSD grep.
- **Symptom**: On macOS, every regression attributes as `UNKNOWN_DRIFT` even when the skill SHA clearly changed.
- **Workaround**: Inspect `env_delta.keys_changed` in `results.json` directly to see what changed.

### BLK-5 · `fix_proposal` enrichment is invisible to users
- **File**: [scripts/eval/lib/diff.sh](./scripts/eval/lib/diff.sh) (render_diff_md never reads `.fix_proposal`)
- **Cause**: `score.sh:294` attaches `.fix_proposal` to every failed check, but `diff.sh:render_diff_md` only renders `failed_check_id`, expected, actual, hint — never the proposal.
- **Symptom**: Headline v0.4.0 feature has zero user-facing surface area. README example showing `fix_proposal: missing tag "architecture"` is **fiction**.
- **Workaround**: Read `~/.config/opencode/eval-harness/runs/<id>/results.json` directly and grep for `fix_proposal`.

### BLK-6 · `--mode=2tier` aggregates verdicts wrong
- **File**: [scripts/eval/twotier.sh:64-76](./scripts/eval/twotier.sh)
- **Cause**: 2tier escalation re-runs each failed case individually with `--mode=full`, each producing its own run dir. The orchestrator exits with the **last** case's rc only.
- **Symptom**: A regression in case A followed by case B passing exits 0. False green.
- **Workaround**: Use `--mode=full` directly. Avoid `--mode=2tier` until fixed.

### BLK-7 · Empty/missing transcript causes `output_not_contains` to vacuous-PASS
- **File**: [scripts/eval/lib/score.sh:252](./scripts/eval/lib/score.sh)
- **Cause**: `output_not_contains` initializes `passed=true` and only flips to false if grep matches. Missing/empty transcript → no match → vacuous PASS.
- **Symptom**: A skill that completely fails to run will score PASS on every negative check.
- **Workaround**: Pair every `output_not_contains` with at least one positive check (`output_contains` or `file_exists`).

### BLK-8 · `timeout(1)` exit 124 silently scored as normal run
- **File**: [scripts/eval/lib/spawn.sh:50-66](./scripts/eval/lib/spawn.sh) → [scripts/eval/run.sh:286](./scripts/eval/run.sh)
- **Cause**: `timeout` returns 124 when it kills opencode. Caller stores `exit_code` as a string but never uses it for any decision.
- **Symptom**: Timed-out runs score against partial/empty transcripts and can produce false PASS (per BLK-7).
- **Workaround**: Set generous `max_seconds` in case YAML budgets to minimize timeout occurrence.

---

## 🟠 HIGH severity (correctness, but with workarounds)

### HIGH-1 · Lock file descriptor + `.d` directory leak on SIGINT/SIGTERM
- **File**: [scripts/eval/run.sh:262-337](./scripts/eval/run.sh)
- **Cause**: No `trap` to release fd 9 / `rmdir` mkdir-lock on Ctrl+C.
- **Symptom**: Next run on same case hangs for `EVAL_LOCK_TIMEOUT` seconds (default 300s).
- **Workaround**: After a Ctrl+C, `rmdir ~/.config/opencode/eval-harness/locks/*.d 2>/dev/null` before retry.

### HIGH-2 · `$RANDOM` run-ID collision space too small
- **File**: [scripts/eval/run.sh:175](./scripts/eval/run.sh)
- **Cause**: `RUN_ID="$(date …)-$RANDOM"` — only 32K possible suffixes.
- **Symptom**: Two parallel CI jobs starting in the same second have a 1-in-32767 chance of identical RUN_ID, corrupting each other's `results.json`.
- **Workaround**: Don't run more than one eval-harness invocation per CI job in the same second.

### HIGH-3 · `history.ndjson` unguarded concurrent appends
- **File**: [scripts/eval/run.sh:362-364](./scripts/eval/run.sh)
- **Cause**: Per-case lockfile protects scoring but not the final history append.
- **Symptom**: Concurrent runs finishing simultaneously can interleave JSONL lines, corrupting `trend.sh` and any downstream consumer.
- **Workaround**: Run evals sequentially in CI; don't fan out parallel eval-harness invocations.

### HIGH-4 · LLM-judge verdict parser can be confused by justification text
- **File**: [scripts/eval/lib/llm_judge.sh:60-63](./scripts/eval/lib/llm_judge.sh)
- **Cause**: First grep matches `"PASS"` or `"FAIL"` in quoted form before falling back to bare-word match. If a `FAIL` verdict's justification contains the word `"PASS"`, the wrong token is picked.
- **Symptom**: False PASS verdicts from a judge that actually said FAIL.
- **Workaround**: Write rubrics that discourage the judge from quoting `PASS`/`FAIL` in justification.

---

## 🟡 MEDIUM (silent-failure modes that mislead diagnosis)

### MED-1 · `propose_fixes_for_run` (autofix.sh:124) is dead code with a tautology bug
- **File**: [scripts/eval/lib/autofix.sh:124-156](./scripts/eval/lib/autofix.sh)
- **Cause**: `select(... | $f | .)` always returns true. Every case ends up with every check from the entire run.
- **Symptom**: None visible — function is never called. But the bug exists if anyone wires it up.

### MED-2 · `python3` + `pyyaml` not preflight-checked
- **File**: [scripts/eval/lib/preflight.sh](./scripts/eval/lib/preflight.sh)
- **Cause**: Preflight only validates `opencode` + provider key.
- **Symptom**: If `yq` binary absent AND `python3`/`pyyaml` absent, every `yq` call silently fails. User sees exit 13 with no hint that python3 is the missing dep.

### MED-3 · `twotier.sh:46` race — `ls -dt` can pick wrong smoke run
- **File**: [scripts/eval/twotier.sh:46](./scripts/eval/twotier.sh)
- **Cause**: Reads `ls -dt $STATE_DIR/runs/*` to find the smoke run; another concurrent run may have created a newer dir.
- **Symptom**: Escalation logic reads the wrong run's `results.json`.
- **Workaround**: Don't run parallel eval-harness invocations targeting the same state dir.

### MED-4 · No baselines ship in-repo
- **Cause**: First-time setup gap.
- **Symptom**: Every first run for any user produces `verdict: FAIL` (no baseline to diff). README "5-min quick start" gives the wrong output.
- **Workaround**: Run `eval-harness baseline --skill=<name>` once before expecting `PASS`.

### MED-5 · Missing `expect_*` field in `shell` check silently scores as FAIL
- **File**: [scripts/eval/lib/score.sh:66-79](./scripts/eval/lib/score.sh)
- **Cause**: No detection of the "no expectation set" misconfiguration.
- **Symptom**: A typo like `expected_regex:` (instead of `expect_regex:`) silently fails the check with no warning.
- **Workaround**: Schema-validate your case YAMLs before committing.

---

## 🟢 Scope limitations (by design, not bugs)

These are features that don't exist yet, not bugs in what does exist.

- **No `--strict` mode** — warn-only is the only mode. CI gating requires manual `promote` first.
- **No `--ci` mode / JUnit / SARIF / PR-comment output** — CI integration is DIY today.
- **No shared-state daily budget ledger** — `EVAL_BUDGET_USD=2.00` is documented but only enforced within a single process.
- **No auto-promotion after N green days** — README implies 7-day rule, but no day-counter exists. `promote.sh` is manual-only.
- **No branch filter for pre-push** — fires on push to any branch including WIP.
- **No cross-skill interaction diagnosis** — `skill_bundle_sha` flags it but doesn't say which other skill is the culprit.
- **No rate-limit / retry logic in LLM judge** — Anthropic 429 = `verdict: null`, no exponential backoff.
- **No judge response caching** — re-running on the same artifact re-burns tokens.
- **No self-eat suite** — eval-harness has no `evals/cases/*.yaml` for itself; can't detect its own regressions via the same pre-push path it offers to others.
- **opencode Stop hook is a scaffold only** — activates when opencode ≥ 1.16 plugin API ships.

---

---

## What's actually safe to use today (v0.4.2 — post-hardening)

| Use case | Status |
|---|---|
| Run on your own structured-output skill | ✅ **Ready** — write cases, run `baseline`, then `run` |
| Run on your own prose-output skill with `llm_judge` | ✅ **Ready** — needs `ANTHROPIC_API_KEY` |
| Wire into `git pre-push` for your own repos | ✅ **Ready in warn-only mode** (default) |
| `--mode=2tier` aggregation | ✅ **Fixed in v0.4.2** — now correctly returns exit 12 if any escalated case is a confirmed regression |
| CI/CD gating on PR builds | ⚠️ Still needs `--strict` mode (v0.5.0) + JUnit/SARIF (v0.5.0) |
| Run cases authored by untrusted parties | ⚠️ **Now safer** with default-on shell-safety filter (v0.4.2 BLK-2), but the threat model is "your case YAMLs", not "arbitrary user input" — review case YAMLs before importing |

---

Last updated: 2026-05-30 (v0.4.2)
