# Security Policy

## Supported versions

| Version | Supported |
|---------|-----------|
| 0.5.x   | ✅ Active |
| 0.4.x   | ⚠️  Security-only |
| < 0.4   | ❌ EOL    |

## Reporting a vulnerability

If you find a security issue in eval-harness — for example, an injection vector in `score_shell`, a path-traversal bypass in fixture copy, or an authentication leak in `llm_judge.sh` — **please do not open a public issue**.

Instead, email **nhoxtvt@gmail.com** with subject line:

```
[eval-harness security] <one-line summary>
```

Include in the body:

1. **Affected version** (`eval-harness --version`)
2. **Reproducer** — minimal commands, case YAML, env vars, or attached repro repo
3. **Impact** — what an attacker can do
4. **Suggested fix** if you have one (optional)

You will get an acknowledgement within **72 hours**. We will work with you on a coordinated disclosure timeline (typically 30–90 days depending on severity).

## Security model

eval-harness does not treat case YAML as a trust boundary and is not an OS sandbox. It fetches skill files from disk and runs OpenCode/runner processes with the harness user's privileges. Use cases from sources you trust; isolate the entire run in a container or VM when evaluating untrusted repositories.

Implicit-safe `kind: shell` checks are parsed into a constrained argv pipeline containing only `jq`, `printf`, and terminal `wc -l`; `jq` input paths must resolve to regular files beneath the workdir, and the default path does not invoke a shell. This narrows command execution but is not a kernel-enforced sandbox. Setting `unsafe_shell: true` or `EVAL_ALLOW_UNSAFE_SHELL=1` runs the command via `bash -c` with the user's permissions.

Fixture paths and grader artifact paths are checked for workdir confinement. LLM-judge prompts are sent to Anthropic when live judging is enabled; never include secrets in case prompts. The harness cannot redact unknown sensitive content.

### Autonomous Test Discovery

`atd-sandbox` is a narrower, explicit exception to the ordinary host runner:
generated candidate tests execute only in the policy-approved Docker image,
with no network, read-only source/dependencies/rootfs, non-root identity,
dropped capabilities, resource limits and a host deadline. Missing confinement
fails closed; it never runs the test on the host. Trusted dependency setup is
separate and requires an explicit network acknowledgement.

This does not make arbitrary case YAML or generic `grade` manifests untrusted
inputs. The discovery workflow generates its own cases and admits only their
fixed layout/check kinds before replay, preventing a rewritten discovery
manifest from inserting host shell commands. Model output cannot provide
grading checks, signer settings or expectation approvals.

Local signatures provide integrity, not independent control from the same OS
user. Blocking, automatic repair requests and QA confirmed-defect promotion
require externally controlled signer trust, stable authenticated differential
evidence and the operator's original review from a separate trusted directory.
Neither a JSON trust label nor rewriting a review and its digest manifest grants
approval. Keep keys outside repositories, case workdirs and all mounted paths.

Residual risks include the shared Docker kernel/VM, same-UID framework/reporting
processes and a writable output mount without a filesystem-wide quota. See the
[discovery guide](./docs/AUTONOMOUS_TEST_DISCOVERY.md#limits-and-verification)
for operational limits. Disk exhaustion, runtime/collection faults and missing
evidence are inconclusive infrastructure results, never regression proof.

## Past security advisories

Hardening release **v0.4.2** (2026-05-30) closed 8 audit-surfaced BLOCKERs including:

- **BLK-2**: `score_shell` previously accepted `$()` command substitution — now rejected.
- **BLK-3**: Fixture copy previously followed `../` path segments — now rejected.
- **BLK-8**: `timeout(1) exit 124` previously scored partial transcripts as PASS — now surfaces as harness error.

Full list in [CHANGELOG.md](./CHANGELOG.md).

## Out of scope

The following are **not** considered security issues:

- LLM-judge returning a wrong verdict (this is a quality issue, not a security one — see issue #6 for `samples_cap`)
- Anthropic API rate-limit responses (we already handle 429 gracefully — see issue #19 for backoff improvements)
- A test author writing a case that intentionally exfiltrates secrets via `output_contains` regex (this is the author's responsibility, not the harness's)
- A skill author writing a malicious opencode skill (this is opencode's threat model, not ours)

We will, however, review reports in this category and may add hardening if the bar is low.
