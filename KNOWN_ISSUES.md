# Known limitations — eval-harness v0.5.0 (unreleased)

This file lists constraints that remain in the current working tree. Resolved findings from earlier audits are historical; they are not carried forward as active issues.

## Operational boundaries

- **Invocation adapter:** `run` invokes OpenCode. Other runtimes can submit content-addressed evidence through `grade`, but must produce the documented case/workdir/transcript/artifact manifest and satisfy the local path policy.
- **Evidence authenticity:** SHA-256 checks detect changed evidence relative to a grading manifest; they do not establish who produced the manifest or artifacts. Do not treat local hashes as signatures or a remote trust root.
- **Cost availability:** Provider cost/token data is not universal. Unmeasured cost stays `null` and is tracked as unavailable; budget gating cannot prove that unavailable spend is zero.
- **Human review:** `human_review` is intentionally unresolved until a reviewer supplies a decision. Strict mode treats pending review as non-passing; it is not an automated quality verdict.

## Measurement limits

- **Stochastic reliability:** pass@k and pass^k are estimated from repeated binary outcomes under an IID assumption. Correlated or changing trials can make those intervals misleading; the result records the assumption rather than claiming calibration.
- **Attribution:** matching environment hashes identify co-occurring changes, not causal explanations. The attribution output labels evidence strength and does not prove which change caused a regression.
- **Domain calibration:** product dimensions, acceptance thresholds, and trajectory expectations must be validated for each skill. Harness fixtures prove contract behavior, not quality on real production workloads.

## Not currently provided

- The grader does not fetch artifacts from a remote store, verify signatures, or dispatch external reviewers.
- Provider-specific cost normalization and cross-provider comparability are not guaranteed.

Report a reproducible correctness or security defect as an issue; distinguish it from these documented boundaries.
