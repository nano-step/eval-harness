# Awesome lists to revisit (and lists to skip entirely)

> Pre-flight check on each list's actual merge activity revealed important shifts. This file is the honest state as of 2026-06-01.

## Lists to SKIP — they're dead

| List | Stars | Last merged PR | Why skip |
|---|---|---|---|
| [Hannibal046/Awesome-LLM](https://github.com/Hannibal046/Awesome-LLM) | 26.8k | **2025-07-30** (11 months ago) | All recent PRs closed unmerged. Maintainer disengaged. Submitting wastes a PR slot. |
| [visenger/awesome-mlops](https://github.com/visenger/awesome-mlops) | 13.9k | **2024-04-22** (24+ months ago) | Effectively abandoned. |
| [e2b-dev/awesome-sdks-for-ai-agents](https://github.com/e2b-dev/awesome-sdks-for-ai-agents) | 1.2k | **2023-11-10** (~2.5 years ago) | 200+ closed unmerged PRs. Submission would land in the graveyard. |
| [e2b-dev/awesome-ai-agents](https://github.com/e2b-dev/awesome-ai-agents) | 28k | active | **Wrong fit.** Their README explicitly says "for agents, NOT SDKs/tools." We're a tool. Their sibling repo (sdks-for-ai-agents) is the right fit but dead. |

**Do not submit to any of these.** A PR closed without merge stays publicly visible and signals "we tried and were rejected" — worse than silence.

## Lists to revisit at higher traction

| List | Stars | Open PR when stars ≥ | Notes |
|---|---|---|---|
| [awesome-langchain](https://github.com/kyrolabs/awesome-langchain) | — | After LangGraph runner ships (v0.8.0) | Need the runner to credibly belong |
| [awesome-test-automation](https://github.com/atinfo/awesome-test-automation) | — | 200 | Might be off-topic; check section fit |
| [awesome-shell](https://github.com/alebcay/awesome-shell) | — | 200 | True structural fit (we're a bash tool) |
| [awesome-actions](https://github.com/sdras/awesome-actions) | — | After Marketplace listing live | Need the Action published first |
| [awesome-claude-code](https://github.com/) | varies | Track Claude-focused lists as they form | Emerging space |

## Lists we already targeted today

See per-list files (`01-` through `03-`) for the 3 viable submissions. Pre-flight check before opening any PR:

```bash
# Is the list active (any merged PR in last 90 days)?
gh pr list -R <owner>/<repo> --state merged --limit 5 --json createdAt --jq '.[].createdAt'

# Is our section the right fit (does it exist + accept tools)?
gh api repos/<owner>/<repo>/contents/README.md -H "Accept: application/vnd.github.raw" | grep -E "^## "

# Is there a contributing doc with strict rules?
gh api repos/<owner>/<repo>/contents/ --jq '.[] | select(.name | test("contrib"; "i")) | .name'
```

Run all three checks before submitting to any new list.
