# Awesome-list PR submissions

> **Process**: I (the agent) open each PR under the `nano-step` account when you say go. Per-PR steps:
>
> 1. Fork target repo to `nano-step/<awesome-list-name>` (`gh repo fork`).
> 2. Clone, branch `add-eval-harness`, edit the README to add the entry under the correct section.
> 3. Commit, push, `gh pr create` against upstream.

## Submission rules each list enforces

| List | Section | Entry format requirement |
|---|---|---|
| [Hannibal046/Awesome-LLM](https://github.com/Hannibal046/Awesome-LLM) | "LLM Evaluation" | `- [Name](url) - Description.` |
| [e2b-dev/awesome-ai-agents](https://github.com/e2b-dev/awesome-ai-agents) | "Open-source projects" → "Frameworks for building" or "Other" | `- [Name](url) - Description with star count + license` |
| [tensorchord/Awesome-LLMOps](https://github.com/tensorchord/Awesome-LLMOps) | "Testing" or "Evaluation" | Alphabetical, `* [name](url) - description.` |
| [taishi-i/awesome-ChatGPT-repositories](https://github.com/taishi-i/awesome-ChatGPT-repositories) | "Testing & evaluation" | `- [name](url) - description.` |
| [steven2358/awesome-generative-ai](https://github.com/steven2358/awesome-generative-ai) | "Developer tools" → "Evaluation" | `- [name](url) - description.` |
| [visenger/awesome-mlops](https://github.com/visenger/awesome-mlops) | "Model Testing" or "Observability" | `- [Name](url): Description.` |

**Always match the list's existing entry style exactly.** Capitalization, sentence terminator, link format — copy a neighbor entry's shape.

## Universal PR body template

Every awesome-list PR body uses the template in `_pr-body-template.md` adapted to each list's style guide. The per-list files in this directory contain:

1. The README diff (what to insert, where).
2. The PR title.
3. The PR body (adapted from the universal template).

## Common rejection reasons + how to pre-empt

- **"Project is too new"** → "v0.4.2 with 20/20 test suites green; documenting honest scope; under active development; happy to revisit after N months if not ready."
- **"Doesn't fit this section"** → Read the README's structure twice. Pick the most specific section. If unsure, ask before opening the PR.
- **"Alphabetical placement wrong"** → Always double-check.
- **"Description too long"** → Keep to ≤ 120 chars after the URL.
- **"Wrong commit author / no DCO sign-off"** → A few lists require DCO. Check CONTRIBUTING.md before pushing.
