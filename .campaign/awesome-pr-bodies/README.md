# Awesome-list PR submissions

> **Process**: I (the agent) open each PR under the `nano-step` account when you say go. Per-PR steps:
>
> 1. Fork target repo to `nano-step/<awesome-list-name>` (`gh repo fork`).
> 2. Clone, branch `add-eval-harness`, edit the README to add the entry under the correct section.
> 3. Commit, push, `gh pr create` against upstream.

## Submission rules each list enforces

| # | List | Status | Section | Entry format |
|---|---|---|---|---|
| 1 | [taishi-i/awesome-ChatGPT-repositories](https://github.com/taishi-i/awesome-ChatGPT-repositories) | **MERGED** #150 | "Testing & evaluation" | `- [name](url) - description.` |
| 2 | [tensorchord/Awesome-LLMOps](https://github.com/tensorchord/Awesome-LLMOps) | OPEN #538 (CLEAN) | "Testing" / "Evaluation" | Alphabetical, `* [name](url) - description.` |
| 3 | [steven2358/awesome-generative-ai](https://github.com/steven2358/awesome-generative-ai) | OPEN #830 (MERGEABLE, just rebased) | "Developer tools" → "Evaluation" | `- [name](url) - description.` |
| 4 | [awesome-opencode/awesome-opencode](https://github.com/awesome-opencode/awesome-opencode) | OPEN #405 (MERGEABLE) | `data/projects/<name>.yaml` (NOT README.md — list is YAML-driven) | `name:`, `repo:`, `tagline:`, `description:` |
| 5 | [kyrolabs/awesome-agents](https://github.com/kyrolabs/awesome-agents) | OPEN #531 (MERGEABLE, CLEAN) | "Testing and Evaluation" | `- [Name](url): description. ![GitHub Repo stars](badge)` |
| 6 | [UKGovernmentBEIS/inspect_ai](https://github.com/UKGovernmentBEIS/inspect_ai) **(real contribution, not listing)** | OPEN #4151 (MERGEABLE, 297 lines new code) | `examples/behavior_regression.py` | New example file demonstrating `ci()` and `mwu_pvalue()` metrics, cross-references eval-harness |

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

## Lists explicitly REJECTED (verified merge rate = 0% or wrong topic)

These lists were surveyed, considered, and **deliberately skipped** because they fail the "will it actually merge" check. Do not re-attempt without strong reason (e.g. maintainer change, repo revival). Source data: `gh pr list --state all --limit 50` for each, collected 2026-06-05.

| List | Stars | Open | Merged | Closed | Why skipped |
|---|---|---|---|---|---|
| [Hannibal046/Awesome-LLM](https://github.com/Hannibal046/Awesome-LLM) | 26.9k | 29 | **0** | 1 | Maintainer pushes own commits but never merges external PRs |
| [ai-boost/awesome-harness-engineering](https://github.com/ai-boost/awesome-harness-engineering) | 1.6k | 28 | **0** | 2 | Same pattern — no merges ever |
| [jim-schwoebel/awesome_ai_agents](https://github.com/jim-schwoebel/awesome_ai_agents) | 1.8k | 46 | **0** | 4 | Maintainer appears inactive on PRs |
| [e2b-dev/awesome-ai-agents](https://github.com/e2b-dev/awesome-ai-agents) | 28.2k | 44 | **0** | 6 | DEAD — last merge 2024-04 |
| [e2b-dev/awesome-sdks-for-ai-agents](https://github.com/e2b-dev/awesome-sdks-for-ai-agents) | — | 44 | **0** | 6 | Same |
| [sdras/awesome-actions](https://github.com/sdras/awesome-actions) | 27.9k | 45 | **0** | 5 | Stale (last push 2024-09) |
| [alebcay/awesome-shell](https://github.com/alebcay/awesome-shell) | 37k | 36 | **0** | 14 | Stale (last push 2025-08) |
| [mojoaxel/awesome-regression-testing](https://github.com/mojoaxel/awesome-regression-testing) | 2.4k | — | — | — | Wrong scope (visual regression, not behavioral) |
| [travisvn/awesome-claude-skills](https://github.com/travisvn/awesome-claude-skills) | 13.2k | — | — | — | eval-harness is a tool not a skill; only 1 PR merged ever |
| [hesreallyhim/awesome-claude-code](https://github.com/hesreallyhim/awesome-claude-code) | 45.8k | — | — | — | Mid-rebuild; "data" dir has no entry mechanism yet |
| [awesome-lists/awesome-bash](https://github.com/awesome-lists/awesome-bash) | 9.8k | — | — | — | Hard rule: older than 90 days AND more than 50★ (eval-harness fails both) |
| [visenger/awesome-mlops](https://github.com/visenger/awesome-mlops) | 13.9k | — | — | — | DEAD (last merge 2024-04-23) |
| [githubnext/awesome-continuous-ai](https://github.com/githubnext/awesome-continuous-ai) | 461 | 4 | 13 | 3 | Wrong entry mechanism — wants issue submission, not PR |
| [punkpeye/awesome-mcp-clients](https://github.com/punkpeye/awesome-mcp-clients) | 6.5k | 19 | 12 | 19 | Wrong topic (MCP clients, not eval) |
| [VoltAgent/awesome-claude-code-subagents](https://github.com/VoltAgent/awesome-claude-code-subagents) | 21.2k | 6 | 7 | 37 | Wrong topic (subagents, not eval) |
| [Shubhamsaboo/awesome-llm-apps](https://github.com/Shubhamsaboo/awesome-llm-apps) | 113k | 2 | 3 | 45 | Very high bar; 6% merge rate |

## Lesson: Pushing commits ≠ Merging external PRs

My initial pre-flight was wrong on two candidates (Hannibal046/Awesome-LLM, ai-boost/awesome-harness-engineering) because I conflated *commit frequency* with *PR-merge responsiveness*. They push their own updates frequently but never merge external contributions — a 0% merge rate is the actual signal.

**New rule**: For every candidate, the pre-flight must include `gh pr list --state all --limit 50 --json state` and compute the **merged/total ratio**. Skip any list with merge rate < 5% unless there's a strong section-fit reason to override.
