#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
WORK="$(mktemp -d -t eval-harness-calibrate.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/gold" "$WORK/bin"
cat > "$WORK/gold/c1.yaml" <<'YAML'
id: c1
rubric: "The artifact is present."
human_verdict: PASS
artifact: "present"
YAML
cat > "$WORK/bin/curl" <<'SH'
#!/usr/bin/env bash
: > "$CALIBRATE_CURL_CALLED"
exit 99
SH
chmod +x "$WORK/bin/curl"
export PATH="$WORK/bin:$PATH"
export CALIBRATE_CURL_CALLED="$WORK/curl-called"
unset ANTHROPIC_API_KEY || true

output="$(bash "$REPO_ROOT/scripts/eval/calibrate.sh" --gold-dir="$WORK/gold" --estimate)"
[[ "$output" == *"1 gold entries x 1 samples = 1 judge calls"* ]] || {
  echo "FAIL: estimate did not report the expected call count: $output" >&2
  exit 1
}
[[ ! -e "$CALIBRATE_CURL_CALLED" ]] || { echo "FAIL: --estimate invoked curl" >&2; exit 1; }
echo "PASS: calibrate --estimate uses the shared judge prompt and makes no API call"
