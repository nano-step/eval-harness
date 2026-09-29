#!/usr/bin/env bash
# Regression test for EV-F: a baseline carries a checks_checksum over its verdict-bearing
# subtree; flipping `passed` (or a check's passed) to launder a regression is detected.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/stability.sh"

WORK="$(mktemp -d -t eval-harness-tamper.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

B="$WORK/c1.baseline.json"
cat > "$B" <<'JSON'
{"schema_version":2,"case_id":"c1","passed":false,"checks":[{"kind":"file_exists","passed":false,"failed_check_id":"file_exists:out.md","actual":"missing"}],"env_manifest":{"model_id":"m"}}
JSON
inject_baseline_checksum "$B"

# Honest baseline verifies.
verify_baseline_integrity "$B" || { echo "FAIL: freshly-checksummed baseline should verify" >&2; exit 1; }
[[ -n "$(jq -r '.checks_checksum' "$B")" ]] || { echo "FAIL: checks_checksum not written" >&2; exit 1; }

# Tamper 1: flip top-level passed false->true (launder a regression) WITHOUT updating checksum.
jq '.passed = true' "$B" > "$B.t" && mv "$B.t" "$B"
if verify_baseline_integrity "$B"; then echo "FAIL: flipped top-level passed not detected" >&2; exit 1; fi

# Restore + re-checksum, then tamper a check's passed.
jq '.passed = false' "$B" > "$B.t" && mv "$B.t" "$B"; inject_baseline_checksum "$B"
verify_baseline_integrity "$B" || { echo "FAIL: re-checksummed baseline should verify" >&2; exit 1; }
jq '.checks[0].passed = true' "$B" > "$B.t" && mv "$B.t" "$B"
if verify_baseline_integrity "$B"; then echo "FAIL: flipped check passed not detected" >&2; exit 1; fi

# A non-verdict field change (actual text) does NOT trip the checksum (checksum is verdict-only).
jq '.passed = false | .checks[0].passed = false' "$B" > "$B.t" && mv "$B.t" "$B"; inject_baseline_checksum "$B"
jq '.checks[0].actual = "different text"' "$B" > "$B.t" && mv "$B.t" "$B"
verify_baseline_integrity "$B" || { echo "FAIL: a non-verdict (actual) change should NOT trip the checksum" >&2; exit 1; }

# Legacy baseline with no checksum is not failed (backward compat).
echo '{"passed":false,"checks":[]}' > "$WORK/legacy.json"
verify_baseline_integrity "$WORK/legacy.json" || { echo "FAIL: legacy (no checksum) baseline must not fail verification" >&2; exit 1; }

echo "PASS: baseline tamper-evidence detects flipped verdicts; tolerates non-verdict edits; legacy-safe"
exit 0
