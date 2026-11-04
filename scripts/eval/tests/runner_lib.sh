#!/usr/bin/env bash
# tests/runner_lib.sh — unit tests for lib/runner.sh.
# Tests resolve/list/register/deregister/dispatch + the opencode-implicit
# contract. Exercises the in-memory registry, filesystem fallback, and
# the opencode no-op behavior for prepare/fingerprint/teardown.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/../lib"

# shellcheck disable=SC1090
source "$LIB/runner.sh"

TMP="$(mktemp -d -t runner-lib-test.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok()   { echo "  ok  - $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL - $1" >&2; FAIL=$((FAIL+1)); }

# 1. list_runners includes "opencode" first
out="$(list_runners)"
first="$(echo "$out" | head -1)"
[[ "$first" == "opencode" ]] && ok "list_runners: opencode is first" || fail "list_runners first='$first'"
echo "$out" | grep -qx "opencode" && ok "list_runners: contains opencode" || fail "list_runners missing opencode"

# 2. resolve_runner opencode -> <implicit:opencode>
got="$(resolve_runner opencode)"
[[ "$got" == "<implicit:opencode>" ]] && ok "resolve opencode -> marker" || fail "resolve opencode='$got'"

# 3. resolve_runner unknown -> error
set +e
bash -c "source '$LIB/runner.sh'; resolve_runner nonexistent-runner-xyz" >/dev/null 2>&1
ec=$?
set -e
[[ "$ec" != "0" ]] && ok "resolve unknown -> nonzero exit" || fail "resolve unknown exit=$ec"

# 4. register + dispatch via the in-memory registry
FAKE="$TMP/fake-runner.sh"
cat > "$FAKE" <<'EOF'
#!/usr/bin/env bash
cmd="${1:-}"
shift || true
case "$cmd" in
  fingerprint) echo "fingerprint-from-fake" ;;
  *) echo "unknown subcommand: $cmd" >&2; exit 2 ;;
esac
EOF
chmod +x "$FAKE"

register_runner fake "$FAKE" >/dev/null
got="$(resolve_runner fake)"
[[ "$got" == "$FAKE" ]] && ok "register: resolve returns registered path" || fail "resolve after register='$got'"

got="$(dispatch_runner fingerprint fake)"
[[ "$got" == "fingerprint-from-fake" ]] && ok "dispatch: hits registered script" || fail "dispatch fingerprint fake='$got'"

# 5. deregister + dispatch now fails
deregister_runner fake >/dev/null
set +e
bash -c "source '$LIB/runner.sh'; _RUNNER_REGISTRY=(); register_runner fake '$FAKE' >/dev/null; deregister_runner fake >/dev/null; resolve_runner fake" >/dev/null 2>&1
ec=$?
set -e
[[ "$ec" != "0" ]] && ok "deregister: resolve fails after deregister" || fail "deregister left runner resolvable"

# 6. filesystem fallback: create a runner in RUNNERS_DIR and dispatch via it
export EVAL_RUNNERS_DIR="$TMP"
cat > "$TMP/fs-runner.sh" <<'EOF'
#!/usr/bin/env bash
cmd="${1:-}"
case "$cmd" in
  fingerprint) echo "fingerprint-from-fs" ;;
  *) echo "unknown" >&2; exit 2 ;;
esac
EOF
chmod +x "$TMP/fs-runner.sh"

got="$(dispatch_runner fingerprint fs-runner)"
[[ "$got" == "fingerprint-from-fs" ]] && ok "dispatch: filesystem fallback works" || fail "dispatch fs-runner='$got'"

# 6b. EVAL_RUNNERS_DIR adds/overrides adapters; it never hides the shipped ones.
SHIPPED="$(cd "$LIB/.." && pwd)/runners"
got="$(resolve_runner fs-runner)"
[[ "$got" == "$TMP/fs-runner.sh" ]] && ok "resolve: override-dir adapter found" || fail "resolve fs-runner='$got'"
for shipped_name in langgraph-node atd-sandbox omp claude-code codex; do
  got="$(resolve_runner "$shipped_name")"
  [[ "$got" == "$SHIPPED/$shipped_name.sh" ]] && ok "resolve: shipped '$shipped_name' still found with EVAL_RUNNERS_DIR set" || fail "resolve $shipped_name='$got'"
done
if resolve_runner nonexistent-runner-xyz >/dev/null 2>&1; then
  fail "resolve: nonexistent runner must still fail with EVAL_RUNNERS_DIR set"
else
  ok "resolve: nonexistent runner still fails with EVAL_RUNNERS_DIR set"
fi
cp "$TMP/fs-runner.sh" "$TMP/omp.sh"
got="$(resolve_runner omp)"
[[ "$got" == "$TMP/omp.sh" ]] && ok "resolve: trusted override takes precedence over the shipped adapter" || fail "resolve omp override='$got'"
out="$(list_runners)"
[[ "$(echo "$out" | head -1)" == "opencode" ]] && ok "list_runners: opencode first with override dir" || fail "list_runners first='$(echo "$out" | head -1)'"
echo "$out" | grep -qx fs-runner && echo "$out" | grep -qx langgraph-node && ok "list_runners: override and shipped adapters both listed" || fail "list_runners missing override/shipped"
[[ "$(echo "$out" | grep -cx omp)" == "1" ]] && ok "list_runners: duplicate name listed once" || fail "list_runners omp count=$(echo "$out" | grep -cx omp)"
rm -f "$TMP/omp.sh"

# 7. unknown subcommand rejected
set +e
bash -c "source '$LIB/runner.sh'; dispatch_runner bogus opencode" >/dev/null 2>&1
ec=$?
set -e
[[ "$ec" != "0" ]] && ok "dispatch: bogus subcommand rejected" || fail "dispatch bogus exit=$ec"

# 8. opencode prepare/fingerprint/teardown are no-ops (KTD2)
# shellcheck disable=SC1090
source "$LIB/spawn.sh" 2>/dev/null || true
for sub in prepare fingerprint teardown; do
  set +e
  bash -c "source '$LIB/runner.sh'; source '$LIB/spawn.sh' 2>/dev/null; dispatch_runner $sub opencode" >/dev/null 2>&1
  ec=$?
  set -e
  [[ "$ec" == "0" ]] && ok "opencode $sub: no-op (exit 0)" || fail "opencode $sub exit=$ec, expected 0"
done

# 9. dispatch_runner with empty name errors
set +e
bash -c "source '$LIB/runner.sh'; dispatch_runner spawn ''" >/dev/null 2>&1
ec=$?
set -e
[[ "$ec" != "0" ]] && ok "dispatch: empty name rejected" || fail "dispatch empty name exit=$ec"

echo
echo "PASS: $PASS    FAIL: $FAIL"
[[ "$FAIL" == "0" ]] || exit 1
exit 0
