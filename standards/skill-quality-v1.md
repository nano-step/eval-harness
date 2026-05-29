# Skill Quality Standard v1 (SQS-1)

**Status**: Draft heuristic — consumed by future `skill-reviewer` skill (not yet shipped)
**Version**: 1.0.0
**Last updated**: 2026-05-29

> ⚠️ **Reliability disclosure (read before using).**
>
> SQS-1 is a **draft heuristic**, not a published standard. It synthesizes
> Anthropic's Skills documentation, OWASP shell-security greps, MCP tool-design
> conventions, and pattern-matching across one author's workspace. There is
> **no published, authoritative skill-quality benchmark** in the industry as of
> May 2026.
>
> Of the 30 checks below:
>
> | Tier | Count | Source | Reliability |
> |---|---|---|---|
> | **Tier 1 — Empirically grounded** | **13** | Anthropic Skills doc (A1–A5, C1, D1, D2), OWASP shell security (E1–E3, E4, E5) | 🟢 High |
> | **Tier 2 — Industry pattern, threshold unspecified** | **7** | MCP tool conventions, prompt-engineering folklore, maintenance practice (B1, B2, C3, C4, D3, F1, F2) | 🟡 Medium |
> | **Tier 3 — Author judgment, needs validation** | **10** | Pattern-matching from one workspace (A4 partial, B3, B4, C2, D4, F3, F4, F5, G1, G2, G3) | 🔴 Low |
>
> Use Tier 1 checks freely. Use Tier 2 with judgment. Treat Tier 3 as "things
> to consider," not "things that pass/fail." Each table cell below is tagged
> with its tier.

## Purpose

SQS-1 codifies what *might* make an opencode skill "good" for **design review** (Job 3).
This is distinct from `eval-harness` (Job 1: behavior regression) and from an
LLM-judge (Job 2: output quality grading).

A skill can pass SQS-1 and still regress (eval-harness catches that).
A skill can pass eval-harness and still fail SQS-1 (skill-reviewer catches that).

## Severity ladder

| Level | Meaning | Gate behavior |
|---|---|---|
| **BLOCK** | Ship-stopper. Skill cannot publish via `sync-skill-to-manager`. | exit 12 |
| **WARN**  | Real issue, user should fix. | exit 0 + stderr warning |
| **INFO**  | Stylistic / quality note. | exit 0 + collected in report |

## Categories

> **Tier legend**: 🟢 grounded · 🟡 industry pattern · 🔴 author judgment

### A — Frontmatter & Metadata

| ID | Tier | Check | Severity |
|---|---|---|---|
| A1 | 🟢 | `name` field present, kebab-case, ≤40 chars | BLOCK |
| A2 | 🟢 | `description` field present, ≥80 chars, ≤500 chars | BLOCK |
| A3 | 🟢 | At least 3 trigger phrases in description | WARN |
| A4 | 🟢 | No duplicate skill name in project + user roots | BLOCK |
| A5 | 🟢 | `compatibility` field if skill depends on external tool | WARN |

### B — Trigger Quality

| ID | Tier | Check | Severity |
|---|---|---|---|
| B1 | 🟡 | No trigger phrase collision with other loaded skills | BLOCK |
| B2 | 🟡 | At least one trigger phrase is ≥3 tokens (specific enough to match user intent) | WARN |
| B3 | 🔴 | No reserved trigger words (`run`, `do`, `make`, `start` alone) | WARN |
| B4 | 🔴 | Triggers cover both verb-led ("create X") and noun-led ("X review") phrasings | INFO |

### C — Description Quality

| ID | Tier | Check | Severity |
|---|---|---|---|
| C1 | 🟢 | Description starts with a verb in third person ("Reviews...", "Generates...", "Validates...") | WARN |
| C2 | 🔴 | Description names the SUBJECT and OUTCOME, not the implementation | WARN |
| C3 | 🟡 | Description includes at least one concrete use case ("Use when X happens") | WARN |
| C4 | 🟡 | Description doesn't promise capabilities the skill doesn't have | BLOCK |

### D — Examples & Output Contract

| ID | Tier | Check | Severity |
|---|---|---|---|
| D1 | 🟢 | At least 1 concrete example in SKILL.md (input → output) | BLOCK |
| D2 | 🟢 | If skill produces structured output, JSON schema documented | WARN |
| D3 | 🟡 | If skill writes files, paths documented | WARN |
| D4 | 🔴 | If skill chains subagents/tools, the call graph is shown | INFO |

### E — Security & Side Effects (HIGHEST PRIORITY)

| ID | Tier | Check | Severity |
|---|---|---|---|
| E1 | 🟢 | No `rm -rf $VAR` or `rm -rf .*$VAR.*` patterns in scripts | BLOCK |
| E2 | 🟢 | No `curl ... \| sh` / `curl ... \| bash` patterns | BLOCK |
| E3 | 🟢 | No `eval $VAR` with unvalidated input | BLOCK |
| E4 | 🟢 | If skill writes outside `.opencode/` or `/tmp/`, paths documented | WARN |
| E5 | 🟢 | If skill makes network calls, hosts documented | WARN |

### F — Maintenance Hygiene

| ID | Tier | Check | Severity |
|---|---|---|---|
| F1 | 🟡 | No references to deprecated MCP servers (configurable blocklist) | WARN |
| F2 | 🟡 | No references to deprecated tool names (configurable blocklist) | WARN |
| F3 | 🔴 | Skill bundle size ≤50KB total (context-load cost) | WARN |
| F4 | 🔴 | Total SKILL.md tokens ≤8k (estimated load cost) | WARN |
| F5 | 🔴 | Last modified within 12 months OR explicitly marked `status: stable` | INFO |

### G — Cross-Skill Impact

| ID | Tier | Check | Severity |
|---|---|---|---|
| G1 | 🔴 | Skill doesn't shadow / contradict another loaded skill's behavior | WARN |
| G2 | 🔴 | If eval-harness has cases targeting this skill, all evals currently green | WARN |
| G3 | 🔴 | Skill duplication: same name in project + user roots resolved by precedence rule | INFO |

## Implementation status

| Job | Tool | Standard |
|---|---|---|
| Job 1: Behavior regression | `eval-harness` (this repo, v0.1.0) | n/a |
| Job 2: Output quality | future eval-harness v0.3 (LLM judge) | n/a |
| Job 3: Design review | future `skill-reviewer` skill | **this document** |

The `skill-reviewer` skill is not part of v0.1.0. SQS-1 is published here so that:
- The standard exists as a versioned reference today
- `skill-reviewer` can be a thin tool implementing checks A1–G3 in a later release
- Users can manually consult SQS-1 to self-review their skills

## Version policy

SQS major versions break: removing a check or moving a check up the severity
ladder is a major version bump. Minor versions add checks at INFO or move
INFO → WARN. Patch versions clarify wording only.

## License

MIT © Hoài Nhớ ([nano-step](https://github.com/nano-step))
