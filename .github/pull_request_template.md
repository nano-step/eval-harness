<!-- Thanks for the PR. Please answer the four prompts below — they make review 10× faster. -->

## What does this PR do?

<!-- One paragraph, plain English. -->

## Why?

<!-- The user-visible problem this fixes, or the design pressure it relieves. -->

## How is it tested?

<!-- Required. eval-harness has a "every fix needs a test" rule (see CONTRIBUTING.md).
     - If you added a new test, name it.
     - If you modified an existing test, say which.
     - If this is docs-only or config-only, write `docs-only` or `config-only`. -->

## Before / after evidence

<!-- Required for behavior changes. Paste the harness output, a diff, or a screenshot.
     Drive-by claims of "it works on my machine" are sent back. -->

---

### Checklist

- [ ] I ran `for t in scripts/eval/tests/*.sh; do bash "$t"; done` and all suites passed
- [ ] I added a test (or updated one) covering the change
- [ ] I updated `CHANGELOG.md` under `## Unreleased`
- [ ] I read [CONTRIBUTING.md](../CONTRIBUTING.md)
- [ ] (If touching `score.sh` or `attribute.sh`) I checked the change works under BSD grep on macOS

<!-- If any box is unchecked, please justify in the PR body. -->
