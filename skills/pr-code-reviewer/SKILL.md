---
name: pr-code-reviewer
description: Review a unified diff for bugs, security issues, and risks. Output to review.md with severity and recommended fix. Triggered by 'review this PR', 'review this diff', or running on diff.patch in the working directory.
version: 0.1.0
---

# pr-code-reviewer (eval-harness demo skill)

Reads `diff.patch` from the working directory. Produces `review.md`.

## Method

1. Parse the diff into hunks
2. For each changed function/block, identify:
   - Security regressions (SQL injection, XSS, command injection, auth bypass)
   - Correctness regressions (race conditions, partial-failure, data loss)
   - Behavior regressions vs. the pre-change version
3. Tag each finding with severity: CRITICAL / HIGH / MEDIUM / LOW
4. For each non-LOW finding, recommend a concrete fix
5. If no findings of severity ≥ MEDIUM, write "Approve" / "LGTM" with brief rationale

## Output format (review.md)

```md
# Code Review: <PR description>

## Severity: <CRITICAL|HIGH|MEDIUM|LOW|APPROVE>

## Findings

### 1. <Finding title> (<severity>)
- File: <path>:<line>
- Issue: ...
- Recommended fix: ...
```

## Anti-patterns

- Demanding tests/docs on a trivial rename
- Stylistic preferences masquerading as blockers
- Vague "consider X" without explanation
- Missing CRITICAL issues to spend tokens on cosmetics
