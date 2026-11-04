# Frozen discovery dataset (no new generation)

Actual Sonnet generations from the local pilot `atd-pilot-20261104-repair-1`, frozen byte-for-byte so CI can
re-evaluate them with the CURRENT pipeline (fresh sandbox executions, fresh signatures) and **zero model calls**.

- `clean/round-001`: intent-aware proposal for the clean refactor.
- `clean/round-002`: mutation-guided proposal for the clean refactor (the model was shown the baseline survivors; the
  original `generation-request.json` is preserved unchanged so `--reevaluate` validates `killsMutantIds` against the
  mutants the model really saw).
- `defect/round-001`: intent-aware proposal for the injected boundary defect.
- `operator-reviews/{clean-guided,defect}`: the operator's original PASS expectation reviews (exact bytes), bound to the
  candidate/test/spec/manifest hashes. They are passed as the TRUSTED `--approval-dir`, never copied into the output.
- `*/round-NNN/round-summary.json` is a labelled **projection**, not the original summary (see `source` inside it).
- `dataset.json` records the provenance (17 generated, 15 statically accepted, 14 selected after one negative veto) and the
  sha256 of every frozen file. `scripts/eval/discovery/ci-evidence.sh` verifies all of them before use.

`clean/round-002/invalid-rect-names` was statically accepted but is not part of the dataset: it asserts error-message
wording the specification does not promise (see `omitted` in `dataset.json`). Candidates and tests are never edited.
