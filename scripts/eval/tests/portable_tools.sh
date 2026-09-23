#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
WORK="$(mktemp -d -t eval-harness-portable.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

# shellcheck source=../lib/portable.sh
source "$SCRIPT_DIR/../lib/portable.sh"

cat > "$WORK/shasum" <<'STUB'
#!/bin/sh
if [ "${1:-}" = "-a" ] && [ "${2:-}" = "256" ]; then
  shift 2
fi
if [ "$#" -eq 0 ]; then
  while IFS= read -r _line; do :; done
  printf 'stdin-fallback  -\n'
else
  for f in "$@"; do
    printf 'file-fallback  %s\n' "$f"
  done
fi
STUB
chmod +x "$WORK/shasum"

cat > "$WORK/gtimeout" <<'STUB'
#!/bin/sh
shift
"$@"
STUB
chmod +x "$WORK/gtimeout"

cat > "$WORK/okcmd" <<'STUB'
#!/bin/sh
printf 'ok\n'
STUB
chmod +x "$WORK/okcmd"

mkdir -p "$WORK/no-timeout-bin"
cp "$WORK/okcmd" "$WORK/no-timeout-bin/okcmd"

printf 'data\n' > "$WORK/file.txt"
PATH="$WORK" portable_sha256_file "$WORK/file.txt" > "$WORK/file-hash.txt"
[[ "$(cat "$WORK/file-hash.txt")" == "file-fallback  $WORK/file.txt" ]] || {
  echo "FAIL: shasum file fallback not used" >&2
  cat "$WORK/file-hash.txt" >&2
  exit 1
}

printf 'data\n' | PATH="$WORK" portable_sha256_stdin > "$WORK/stdin-hash.txt"
[[ "$(cat "$WORK/stdin-hash.txt")" == "stdin-fallback  -" ]] || {
  echo "FAIL: shasum stdin fallback not used" >&2
  cat "$WORK/stdin-hash.txt" >&2
  exit 1
}

printf 'b\0a\0' | portable_sort_nul | python3 -c '
import sys

data = sys.stdin.buffer.read()
if data != b"a\0b\0":
    print(f"FAIL: portable_sort_nul returned {data!r}", file=sys.stderr)
    sys.exit(1)
'

[[ "$(PATH="$WORK" run_with_timeout 5 okcmd)" == "ok" ]] || {
  echo "FAIL: gtimeout fallback not used" >&2
  exit 1
}

[[ "$(PATH="$WORK/no-timeout-bin:/usr/bin:/bin:/usr/sbin:/sbin" run_with_timeout 5 okcmd)" == "ok" ]] || {
  echo "FAIL: python3 timeout fallback not used" >&2
  exit 1
}

if PATH="$WORK/no-timeout-bin:/usr/bin:/bin:/usr/sbin:/sbin" run_with_timeout 1 sleep 2; then
  echo "FAIL: python3 timeout fallback did not time out" >&2
  exit 1
else
  rc=$?
  [[ "$rc" == "124" ]] || {
    echo "FAIL: python3 timeout fallback returned $rc, expected 124" >&2
    exit 1
  }
fi

cp "$REPO_ROOT/scripts/eval/hooks/pre-push" "$WORK/pre-push-copy"
chmod +x "$WORK/pre-push-copy"
"$WORK/pre-push-copy" origin git@example.invalid </dev/null

mkdir -p "$WORK/hook-bin"
cat > "$WORK/hook-bin/eval-harness" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$EVAL_HARNESS_STUB_LOG"
exit 0
STUB
chmod +x "$WORK/hook-bin/eval-harness"

HOOK_REPO="$WORK/hook-repo"
mkdir -p "$HOOK_REPO/.opencode/skills/foo"
git -C "$HOOK_REPO" init -q
git -C "$HOOK_REPO" config user.email test@example.invalid
git -C "$HOOK_REPO" config user.name "Test User"
printf 'old\n' > "$HOOK_REPO/.opencode/skills/foo/SKILL.md"
git -C "$HOOK_REPO" add .opencode/skills/foo/SKILL.md
git -C "$HOOK_REPO" commit -q -m initial
base_sha="$(git -C "$HOOK_REPO" rev-parse HEAD)"
printf 'new\n' >> "$HOOK_REPO/.opencode/skills/foo/SKILL.md"
git -C "$HOOK_REPO" add .opencode/skills/foo/SKILL.md
git -C "$HOOK_REPO" commit -q -m update-skill
head_sha="$(git -C "$HOOK_REPO" rev-parse HEAD)"

EVAL_HARNESS_STUB_LOG="$WORK/harness.log" \
  PATH="$WORK/hook-bin:$PATH" \
  bash -c "cd '$HOOK_REPO' && '$REPO_ROOT/scripts/eval/hooks/pre-push' origin git@example.invalid" <<EOF
refs/heads/main $head_sha refs/heads/main $base_sha
EOF

if ! grep -q -- '--skill=foo --trigger=pre-push' "$WORK/harness.log"; then
  echo "FAIL: pre-push did not invoke eval-harness for changed skill foo" >&2
  cat "$WORK/harness.log" >&2 || true
  exit 1
fi

cat > "$WORK/hook-bin/eval-harness" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$EVAL_HARNESS_STUB_LOG"
exit 12
STUB
chmod +x "$WORK/hook-bin/eval-harness"

set +e
EVAL_HARNESS_STUB_LOG="$WORK/harness-fail.log" \
  PATH="$WORK/hook-bin:$PATH" \
  bash -c "cd '$HOOK_REPO' && '$REPO_ROOT/scripts/eval/hooks/pre-push' origin git@example.invalid" <<EOF
refs/heads/main $head_sha refs/heads/main $base_sha
EOF
hook_rc=$?
set -e
if [[ "$hook_rc" != "12" ]]; then
  echo "FAIL: pre-push returned $hook_rc, expected eval-harness exit code 12" >&2
  cat "$WORK/harness-fail.log" >&2 || true
  exit 1
fi

if grep -Eq 'grep -[^[:space:]]*P' "$REPO_ROOT/scripts/eval/hooks/pre-push"; then
  echo "FAIL: pre-push hook must not require grep -P" >&2
  exit 1
fi

if grep -Eq '(^|[[:space:]])timeout[[:space:]]+60' "$REPO_ROOT/scripts/eval/hooks/pre-push"; then
  echo "FAIL: pre-push hook must use run_with_timeout" >&2
  exit 1
fi

if grep -Eq 'sort[[:space:]]+-z' "$REPO_ROOT/scripts/eval/lib/manifest.sh"; then
  echo "FAIL: manifest.sh must not require GNU sort -z" >&2
  exit 1
fi

if grep -Eq '(^|[[:space:]])declare[[:space:]]+-A($|[[:space:]])' "$REPO_ROOT/scripts/eval/run.sh"; then
  echo "FAIL: run.sh must not require Bash 4 associative arrays" >&2
  exit 1
fi

if grep -Eq '(^|[[:space:]])mapfile($|[[:space:]])' "$REPO_ROOT/scripts/eval/run.sh"; then
  echo "FAIL: run.sh must not require Bash 4 mapfile" >&2
  exit 1
fi

echo "PASS: portable tool fallbacks cover shasum and gtimeout"
