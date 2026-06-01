# Security Policy

## Supported versions

| Version | Supported |
|---------|-----------|
| 0.4.x   | ✅ Active |
| 0.3.x   | ⚠️  Security-only, until 2026-09-01 |
| < 0.3   | ❌ EOL    |

## Reporting a vulnerability

If you find a security issue in eval-harness — for example, an injection vector in `score_shell`, a path-traversal bypass in fixture copy, or an authentication leak in `llm_judge.sh` — **please do not open a public issue**.

Instead, email **nhoxtvt@gmail.com** with subject line:

```
[eval-harness security] <one-line summary>
```

Include in the body:

1. **Affected version** (`eval-harness --version`)
2. **Reproducer** — minimal commands, case YAML, env vars, or attached repro repo
3. **Impact** — what an attacker can do
4. **Suggested fix** if you have one (optional)

You will get an acknowledgement within **72 hours**. We will work with you on a coordinated disclosure timeline (typically 30–90 days depending on severity).

## Security model

eval-harness runs **user-supplied shell commands** in case YAMLs and **fetches user-supplied skill files** from disk. It is **not** designed to be a sandbox against malicious case authors. If you are running cases authored by people you do not trust, you must add additional isolation (containers, VMs, jails) yourself.

Specifically:

- `kind: shell` checks **are** filtered by `score_shell_is_unsafe` (no `rm`, no `curl`, no `$()`, no backticks, no `>` redirection) unless `unsafe_shell: true` is explicitly set in the case.
- Fixture paths **are** rejected if they contain `..` segments or are absolute (per `fixture_path_traversal.sh` test).
- LLM-judge prompts **are** sent to Anthropic's API. Do not put secrets in your case prompts. The harness redacts known env-var patterns; it cannot redact what it does not know about.

## Past security advisories

Hardening release **v0.4.2** (2026-05-30) closed 8 audit-surfaced BLOCKERs including:

- **BLK-2**: `score_shell` previously accepted `$()` command substitution — now rejected.
- **BLK-3**: Fixture copy previously followed `../` path segments — now rejected.
- **BLK-8**: `timeout(1) exit 124` previously scored partial transcripts as PASS — now surfaces as harness error.

Full list in [CHANGELOG.md](./CHANGELOG.md).

## Out of scope

The following are **not** considered security issues:

- LLM-judge returning a wrong verdict (this is a quality issue, not a security one — see issue #6 for `samples_cap`)
- Anthropic API rate-limit responses (we already handle 429 gracefully — see issue #19 for backoff improvements)
- A test author writing a case that intentionally exfiltrates secrets via `output_contains` regex (this is the author's responsibility, not the harness's)
- A skill author writing a malicious opencode skill (this is opencode's threat model, not ours)

We will, however, review reports in this category and may add hardening if the bar is low.
