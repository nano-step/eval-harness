# Campaign artifacts

> **Internal-only.** These files are working drafts for the 2k-stars contributor campaign. They live on the `campaign/2k-stars` branch and are not advertised externally.
>
> **Do not link to these from the main README, blog, or any external surface.** They contain post copy you will refine before publishing under your own account.

## Layout

```
.campaign/
├── README.md                       # this file
├── posts/                          # launch content drafts
│   ├── 01-hn-show-post.md          # HN Show post + response playbook
│   ├── 02-reddit-localllama.md     # r/LocalLLaMA
│   ├── 03-reddit-claudeai-mlops.md # r/ClaudeAI + r/mlops (two posts)
│   ├── 04-blog-attribution.md      # blog post: 4-class attribution
│   ├── 05-blog-6-field-fail.md     # blog post: 6-field FAIL schema
│   ├── 06-blog-flaky-llm-tests.md  # blog post: 3-sample stability
│   └── 07-x-thread.md              # 8-tweet thread + reply playbook
├── awesome-pr-bodies/              # PR copy for awesome-list submissions
│   ├── README.md                   # how to use these
│   ├── awesome-llm.md              # Hannibal046/Awesome-LLM
│   ├── awesome-ai-agents.md        # e2b-dev/awesome-ai-agents
│   ├── awesome-llmops.md           # tensorchord/Awesome-LLMOps
│   ├── awesome-chatgpt-repos.md    # taishi-i/awesome-ChatGPT-repositories
│   ├── awesome-generative-ai.md    # steven2358/awesome-generative-ai
│   └── awesome-mlops.md            # visenger/awesome-mlops
└── CAMPAIGN.md                     # handoff doc — what humans must do over 12 mo
```

## Sequencing

The recommended order:

1. **Tomorrow morning**: merge PR #30 (the foundation commit) into `main`. That makes the topics/docs/action live.
2. **+2 days**: record the demo GIF via `vhs docs/assets/demo.tape`, commit it, push.
3. **+3 days**: publish the GitHub Action to Marketplace (via Releases tab on the repo — see [action README](../.github/actions/eval-harness/README.md)).
4. **+4 days**: open the 6 awesome-list PRs (parallel — each is ~5 min).
5. **+7 days**: publish blog post `04-blog-attribution.md` on your blog + dev.to.
6. **+10 days**: HN Show post — Tuesday 8am PST. Use `01-hn-show-post.md` verbatim for title/URL/body.
7. **+10 days, 1 hour after HN**: post `02-reddit-localllama.md` to r/LocalLLaMA.
8. **+11 days**: `03-reddit-claudeai-mlops.md` Post A to r/ClaudeAI.
9. **+12 days**: `03-reddit-claudeai-mlops.md` Post B to r/mlops.
10. **+14 days**: blog post `05-blog-6-field-fail.md`.
11. **+14 days, same morning**: X thread `07-x-thread.md`.
12. **+21 days**: blog post `06-blog-flaky-llm-tests.md`.

Each step builds awareness on the previous. Spacing matters more than density — if you post everything in 48 hours, only the HN crowd sees it.

## What you do, what I (the agent) cannot do

I cannot:
- Click "submit" on HN, Reddit, dev.to, Medium, X.
- Make the HN post reach the front page.
- Force awesome-list maintainers to merge PRs.

I can:
- Draft the content (done — see `posts/`).
- Open the awesome-list PRs once you say go.
- Track the KPI weekly via the script at `scripts/eval/tools/stars-kpi.sh`.
- Reconvene to draft v0.5.0 / v0.6.0 / v0.7.0 release notes when those ship.
