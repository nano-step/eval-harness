# Hooks

| Hook | File | Status | Triggers |
|---|---|---|---|
| git pre-push | `pre-push` | ✅ stable | local `git push` when `.opencode/skills/**` touched |
| sync-skill-to-manager | `sync-publish.sh` | ✅ stable | invoked from `sync-skill-to-manager` skill pre-publish |
| opencode Stop | `opencode-stop.sh` | 🚧 scaffold | requires opencode ≥ 1.16.x plugin API |

## opencode Stop hook (scaffold)

**Why it's scaffold:** opencode 1.15.10's plugin API does not stably expose
the post-tool / session-idle Stop lifecycle with a changed-files set. The hook
runner expects `OPENCODE_CHANGED_FILES` (NUL-separated) populated by the
opencode plugin host. Until that lands and is verified, this hook ships as
documented scaffolding only.

**Manual invocation today (for testing):**

```bash
OPENCODE_CHANGED_FILES=$'/path/to/.opencode/skills/my-skill/SKILL.md\0' \
  bash scripts/eval/hooks/opencode-stop.sh
```

**Once opencode 1.16+ lands, wire it via** `~/.config/opencode/hooks.yaml`:

```yaml
on_stop:
  - command: bash
    args: ["/path/to/eval-harness/scripts/eval/hooks/opencode-stop.sh"]
```

The hook is a no-op (exit 0) when:
- `opencode` is not on PATH
- `opencode --version` reports < 1.16.0
- no files in the changed-set are under `.opencode/skills/`
