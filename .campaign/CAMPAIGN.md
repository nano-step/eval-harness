# Campaign handoff — 2k stars goal, 12 months

> **What was done by the agent on 2026-06-01 (1 session, ~3 hours):** every controllable lever set. Topics, description, Discussions, badges, docs, GitHub Action, issue templates, labels, 5 GFIs, LangGraph runner issue, KPI script, awesome-list PRs, launch content drafts. **What only humans can do**: publish content, reply to maintainers, ship the v0.5+ releases, sustain the work over months.
>
> Honest forecast: with disciplined execution of this plan, **1200–2500 stars in 12 months is the realistic range**. 2000 is achievable but not guaranteed. 1000 is the comfortable target.

---

## What is live RIGHT NOW

| Surface | Status | Link |
|---|---|---|
| Repo topics (14) | ✅ Live | https://github.com/nano-step/eval-harness |
| Description rewrite (broader pitch) | ✅ Live | (visible on repo page) |
| Discussions enabled + 3 seed threads | ✅ Live | https://github.com/nano-step/eval-harness/discussions |
| Foundation PR #30 (badges, docs, action, templates) | 🟡 Open, **awaiting your merge** | https://github.com/nano-step/eval-harness/pull/30 |
| 5 GFIs (#31, #32, #33, #34, #35) | ✅ Live, pinned where appropriate | https://github.com/nano-step/eval-harness/issues?q=is%3Aissue+is%3Aopen+label%3A%22good+first+issue%22 |
| LangGraph runner issue #36 | ✅ Live + pinned | https://github.com/nano-step/eval-harness/issues/36 |
| awesome-ChatGPT-repositories PR | 🟡 Open | https://github.com/taishi-i/awesome-ChatGPT-repositories/pull/150 |
| Awesome-LLMOps PR | 🟡 Open | https://github.com/tensorchord/Awesome-LLMOps/pull/538 |
| awesome-generative-ai PR | 🟡 Open | https://github.com/steven2358/awesome-generative-ai/pull/830 |

## What is drafted, awaiting your hand to publish

| Asset | File | Where to publish | When |
|---|---|---|---|
| HN Show post + reply playbook | `.campaign/posts/01-hn-show-post.md` | https://news.ycombinator.com/submit | Tue/Wed 8am PST, after PR #30 merged |
| r/LocalLLaMA post | `.campaign/posts/02-reddit-localllama.md` | reddit.com/r/LocalLLaMA/submit | 1 hour after HN post |
| r/ClaudeAI + r/mlops posts | `.campaign/posts/03-reddit-claudeai-mlops.md` | their submit pages | +1 day, +2 days after HN |
| Blog: 4-class attribution | `.campaign/posts/04-blog-attribution.md` | your blog → dev.to → Medium | First content beat — publish BEFORE HN |
| Blog: 6-field FAIL schema | `.campaign/posts/05-blog-6-field-fail.md` | same | +1 week after first blog |
| Blog: flaky LLM tests | `.campaign/posts/06-blog-flaky-llm-tests.md` | same | +2 weeks |
| X/Twitter thread (8 tweets) | `.campaign/posts/07-x-thread.md` | x.com/compose | Same morning as 2nd blog |

---

## Critical path (next 14 days)

### Day 0 (today, 2026-06-01)

- [x] Topics set on repo
- [x] Description rewritten
- [x] Discussions enabled
- [x] Foundation PR #30 opened
- [x] 6 new issues opened, pinned, labeled
- [x] 3 awesome-list PRs opened
- [x] Content drafts committed to `.campaign/`
- [ ] **YOU**: review and merge PR #30 (or ask for changes). This must happen before anything else. The badges/docs/action need to be on `main` for awesome-list reviewers to see them.

### Day 1–2

- [ ] **YOU**: record the demo GIF
  ```bash
  brew install vhs
  cd /Users/nhonh/Documents/personal/eval-harness
  vhs docs/assets/demo.tape
  git add docs/assets/demo.gif
  git commit -m "demo: hero GIF for README"
  git push
  ```
- [ ] **YOU**: respond to any awesome-list maintainer comments on PRs #150, #538, #830

### Day 3

- [ ] **YOU**: publish GitHub Action to Marketplace
  - Go to https://github.com/nano-step/eval-harness/releases
  - Click "Draft a new release", tag `v0.4.3-action` or similar
  - Check the "Publish this Action to the GitHub Marketplace" box
  - Pick category: `Testing`, `Continuous integration`
  - Submit

### Day 4

- [ ] **YOU**: publish blog post `04-blog-attribution.md`
  - First on your own blog (sets canonical URL)
  - Then dev.to with `canonical_url:` set
  - Then Medium "Import a story"

### Day 5

- [ ] **YOU**: X thread `07-x-thread.md` — tease the blog post

### Day 7 (Tuesday)

- [ ] **YOU**: HN Show post at 8am PST. Use `01-hn-show-post.md` verbatim.
- [ ] **YOU**: 1 hour later, r/LocalLLaMA post.

### Day 8–9

- [ ] **YOU**: r/ClaudeAI post (day 8), r/mlops post (day 9). Stagger them.

### Day 14

- [ ] **YOU**: second blog post `05-blog-6-field-fail.md`.
- [ ] **YOU**: run KPI script, snapshot the state.
  ```bash
  bash scripts/eval/tools/stars-kpi.sh
  ```

---

## Weekly cadence (months 1–6)

Every Monday morning:

```bash
bash scripts/eval/tools/stars-kpi.sh   # 30 seconds
```

It prints star delta + traffic + referrers + which awesome-list star floors are crossed. Append `KPI history file: ~/.eval-harness/kpi-history.ndjson` to ndjson for trend.

Every Friday afternoon:

- Triage GFI claims. If someone commented "I'll take this", check whether they have a PR within 7 days. If not, free the issue.
- Reply to Discussions. Even 1 substantive reply/week keeps the activity signal alive.

Every release (v0.5.0, v0.6.0, ...):

- Write release notes that read like changelogs people care about (not changelogs your tests pass).
- Cross-post the release on X (1 tweet).
- If the release adds an opportune feature for a HN repost (e.g. auto-fix applier, LangGraph runner shipping, web dashboard) — repost. Wait 90+ days between HN reposts.

---

## When to open the deferred awesome-list PRs

`.campaign/awesome-pr-bodies/04-revisit-later.md` has the full list. The trigger conditions:

| Threshold | Action |
|---|---|
| 100 stars | Try `awesome-shell` (true structural fit — we're a bash tool) |
| 200 stars | Try `awesome-test-automation` |
| Once LangGraph runner ships (v0.8.0) | Try `awesome-langchain` |
| Once Action is in Marketplace | Try `awesome-actions` |

Run `bash scripts/eval/tools/stars-kpi.sh` weekly — the script tells you which thresholds have been crossed.

**Do NOT** open PRs to dead lists (Hannibal046/Awesome-LLM, visenger/awesome-mlops, e2b-dev/awesome-sdks-for-ai-agents) — see `04-revisit-later.md` for why.

---

## What you should NOT do (anti-patterns)

1. **Don't ask friends to star the repo.** GitHub's anti-spam tools detect coordinated stars. Stars from non-engaged accounts get reset.
2. **Don't post identical body text to multiple Reddit subs.** Reddit auto-detects. Rewrite each.
3. **Don't comment on every HN/Reddit thread with "star us!"** — kills your credibility instantly.
4. **Don't reply to negative comments defensively.** Acknowledge and redirect. Hostile maintainer replies cost more stars than they save.
5. **Don't ship more than one HN/Reddit post per channel in a 90-day window.** Repost = blacklist.
6. **Don't add features that aren't on the roadmap to "stay competitive".** Scope creep is the #1 killer of small OSS projects.

---

## What success looks like at each milestone

### 100 stars (target: week 4–6 after launch)

- HN post landed on front page or had a high-quality 50-comment thread
- At least 1 awesome-list PR merged
- 1–2 outside contributors (issues commented on, not necessarily PRs)

### 500 stars (target: month 3–4)

- 2+ awesome lists merged
- v0.5.0 (auto-fix applier) shipped
- LangGraph runner issue has 1+ engaged commenter
- 5+ outside contributors in some form
- Blog posts on the canonical URL ranking in Google for "LLM regression testing"

### 1000 stars (target: month 6–8)

- Mentioned in a TLDR AI / Ben's Bites / AlphaSignal issue
- Active GitHub Discussions (5+ unique people across threads)
- 2nd HN/Reddit beat (different angle — auto-fix applier, or LangGraph)
- v0.7.0 or v0.8.0 shipped
- 10+ contributors

### 2000 stars (target: month 10–12)

- Either a major framework recommended it OR an Anthropic eng blogged it OR a16z-style dev tools blog covered it
- Active community managing itself (you reply to ~30% of issues; the rest get answered by others)
- Production usage at 2+ named companies (case studies)
- v1.0.0 stable

If you're at 1000 stars by month 12, that's a real success. Don't beat yourself up if 2000 doesn't land. Most niche OSS infra tools never crack 500.

---

## Things I (the agent) will help with on follow-up sessions

In future sessions, ping me with one of these:

- "Run the KPI snapshot" → I run the script, show delta
- "Draft v0.5.0 release notes" → I write them in your voice
- "Review the HN comments and suggest replies" → I pattern-match against the playbook
- "Open awesome-shell PR" → I do the fork → branch → edit → PR cycle
- "Triage Discussions" → I read the threads, suggest replies, you approve
- "Update CAMPAIGN.md with current state" → I sync the doc to reality

Things I cannot help with even on follow-up:

- Posting to HN / Reddit / X / blog under your name (auth, account, voice)
- Forcing awesome-list maintainers to merge (we wait)
- Making the HN algorithm work in our favor (timing, luck, content quality)

---

## Final note

You asked for "do not pause until you reach the goal." I paused because **the goal needs humans for the parts I can't do**. The campaign is set up with every controllable lever pulled. The next 12 months are execution, not orchestration. Show up weekly, ship the releases, publish the content, respond to people. Stars follow.

Good luck. Pin this doc.
