# Versioning & Deprecation Policy

**Applies to:** `@nano-step/eval-harness` — current working-tree version: **v0.5.0 (unreleased)**

This document defines what constitutes a breaking change, how deprecation works,
and what schema compatibility guarantees consumers can rely on.

---

## Semver

eval-harness follows [Semantic Versioning 2.0.0](https://semver.org/).

### MAJOR — breaking changes

A breaking change requires a MAJOR bump after `1.0.0`; during `0.x`, it may ship in the next MINOR version only with an explicit breaking-change notice and migration path.

- **A CLI flag is removed or renamed.**
  Example: removing `--strict` or renaming `--mode` to `--tier`.
- **A case YAML field is removed or renamed.**
  Example: removing the top-level `checks:` key, or renaming `kind: shell` to
  `kind: bash`.
- **A check kind is removed.**
  Example: removing `jq_path_contains` so existing case files referencing it
  become invalid.
- **Existing CLI/YAML/output contract is incompatible.** Removing a flag, case field, check kind, status field, or changing the meaning of an existing non-opt-in operation is breaking.
- **Exit meanings are reassigned.** Current codes: 0 pass or warn-only, 12 blocking regression/threshold, 13 harness error, 14 strict measured failure, 15 strict pending review, 16 strict indeterminate evidence, and 2 invalid invocation.
- **Schema compatibility is withdrawn.** Results, baseline, environment-manifest, or grading-manifest readers may no longer ignore documented optional/additive fields.

> While the package is in `0.x`, SemVer permits a breaking change in the next `0.(x+1).0` release. Such a release must be explicitly labeled breaking and include a migration path; PATCH releases remain non-breaking. After `1.0.0`, breaking changes require a MAJOR bump.

### MINOR — additive changes (and documented 0.x breaking changes)

A MINOR bump (e.g. `0.4.2 → 0.5.0`) normally covers additive APIs and backward-compatible behavior extensions:

- New check kinds, eval types, optional case fields, result fields, and manifest fields. The v0.5.0 kinds include metric_score, trajectory, and human_review alongside shell, jq_path_contains, file_exists, output_contains, output_not_contains, and llm_judge.
- New commands or flags, including provider-neutral grade manifests and A/B model overrides.
- New typed result statuses and opt-in strict exit codes, provided the default warn-only mode and legacy passed field remain available.
- New evidence-attribution classes, provided existing meanings remain stable and classes describe observation rather than unproven causality.
- An additive schema bump with documented legacy-read compatibility. Results are schema 3, environment manifests schema 4, baselines schema 3, and grading manifests schema 1 in v0.5.0.
- **v0.5.0 breaking shell-check change:** implicit-safe shell checks no longer execute arbitrary Bash commands. Use jq/printf/wc -l expressions, migrate to a typed grader, or set unsafe_shell: true only for trusted case authors; that opt-in executes with the harness user's permissions. This is a documented 0.x MINOR breaking change.
- A 0.x MINOR release may instead carry a documented breaking change under SemVer §4; identify it in CHANGELOG.md and provide a migration path.

### PATCH — non-breaking fixes

A PATCH bump (e.g. `0.4.2 → 0.4.3`) covers:

- Bug fixes (e.g. the `EVAL_BYPASS=1` crash fixed in v0.4.2).
- Performance improvements (e.g. faster fixture diffing).
- Documentation and README updates.
- Internal refactors that do not change observable behaviour or public API
  surface (flags, exit codes, YAML fields, check kinds, output format).

---

## Deprecation

### Announcement window

Deprecated features are announced **at least one MINOR version before
removal**. A feature deprecated in v0.5.0 will not be removed before v0.6.0.

### Error message format

When a removed feature is invoked, the harness emits a clear, actionable error
to stderr and exits `1`:

```
EVAL_X was removed in v0.N; use EVAL_Y instead.
See https://github.com/nano-step/eval-harness/blob/main/CHANGELOG.md#vN
```

Examples below are placeholders only; they do not declare a planned rename or removal.

```
# Hypothetical removed variable
EVAL_OLD_SETTING was removed in v0.N; use EVAL_NEW_SETTING instead.
See the changelog entry for the actual removing release.
```

The link must resolve to the CHANGELOG section for the removing release.

### CHANGELOG sections

- The announcing release carries a Deprecated section listing the field and future removal version.
- The removing release carries a Removed section with the same item and a migration path.

Example CHANGELOG excerpt (illustrative only):

```markdown
## [0.x.y] — Unreleased

### Deprecated
- EVAL_OLD_SETTING: renamed to EVAL_NEW_SETTING. Removal is scheduled for a later release.

## [0.x.z] — Unreleased

### Removed
- EVAL_OLD_SETTING (deprecated previously). Use EVAL_NEW_SETTING instead.
```

### Currently active env vars

The following variables are active in the v0.5.0 working tree and are not deprecated:

| Variable | Purpose |
|---|---|
| EVAL_BUDGET_USD | Daily measured-cost cap. Unavailable ledger cost blocks later budget-gated runs until reconciled. |
| EVAL_MODEL | Model override for OpenCode runs. |
| EVAL_MAX_SECONDS | Per-case wall-clock timeout. |
| EVAL_BYPASS | Set to 1 to skip evaluation and append a bypass event. |
| EVAL_STRICT | Set to 1 to block on non-PASS outcomes. |

---

## File schema compatibility

- results.json uses schema 3. The legacy passed boolean remains; typed statuses, eval_type, regression, quality dimensions, reliability, resource coverage, and grading-manifest references are additive to the documented contract.
- Baseline records use schema 3, retain `source_run_id` for resolving grading-manifest references, and retain the verdict-bearing checks checksum. Schema-2 baselines remain readable.
- Environment manifests use schema 4. Schema_version is ignored as an environment drift signal; prompt/rubric/tool hashes introduced in schema 4 are ignored when absent from a legacy baseline.
- Provider-neutral grading manifests use schema 1 and require digests for available case/workdir/transcript/artifact/environment evidence. Unsupported manifest versions or tampered content are rejected.
- Consumers of results, baseline, or environment-manifest files must ignore unknown additive fields and handle absent optional fields. A breaking change to a required field or its semantics requires a breaking release.

---

## Measurement boundaries

### Case outcome

A case outcome is PASS, FAIL, ERROR, NEEDS_REVIEW, or INDETERMINATE. A baseline regression is only a baseline-PASS to current-FAIL transition when baseline comparison is enabled. Missing evidence is not a PASS and is not a measured zero.

### Product-quality dimensions

Declared metric_score checks may report weighted means within named dimensions. Missing or unavailable values make that dimension unavailable; no global score is computed. These case-level measurements belong in results.json because they describe the evaluated artifact.

### Harness-validity metrics

Meta-evaluation (false-positive/false-negative rates and attribution accuracy) and grader calibration measure the harness, not the skill. They remain separate artifacts such as metaeval.json and calibration.json; do not mix them into case quality dimensions or use them as a substitute for case evidence.

### Invariant

Product-quality measurements and harness-validity measurements are distinct. Product dimensions may be present in results.json; meta-evaluation and calibration records must remain separate. New check kinds do not imply a global quality score, and attribution classes describe observed changes rather than causal proof.

---

## Deprecation and release rule

In 0.x, breaking changes may ship in the next 0.x minor version, but must be called out as breaking in CHANGELOG.md and accompanied by a migration path. Deprecated fields or flags are announced at least one minor release before removal. The working-tree v0.5.0 changes are unreleased; do not treat this policy update as a publication notice.

## Questions & edge cases

Open an issue at <https://github.com/nano-step/eval-harness/issues> if a planned change does not fit these rules. When in doubt, prefer additive fields and explicit status transitions over silent fallback behavior.

