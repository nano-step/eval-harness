#!/usr/bin/env bash
# scripts/eval/discovery/setup-deps.sh — build the trusted dependency snapshot for atd-sandbox.
#
#   setup-deps.sh --lockfile-dir=<dir with package.json + package-lock.json> --allow-network
#                 [--out=<snapshot dir>] [--image=<allowed image ref>]
#
# This is an EXPLICIT, SEPARATE, TRUSTED setup action. It is the only step in the discovery workflow that
# uses the network: it runs `npm ci --ignore-scripts` from a lockfile inside a pinned container (no install
# scripts, no credentials, no host HOME, no Docker socket, non-root, capabilities dropped). It is never part
# of an ordinary discovery run, and generated tests never run here. The resulting snapshot is mounted
# read-only into both sides of every atd-sandbox comparison.
#
# Snapshot layout: <out>/node_modules, <out>/package.json, <out>/package-lock.json, <out>/snapshot.json
# Default <out>: ${EVAL_STATE_DIR:-~/.config/opencode/eval-harness}/discovery/deps/<lockfile-sha256>
# The last line printed on success is the snapshot directory.

set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLICY="$SELF_DIR/policy/atd-sandbox.v1.json"

die() { echo "[atd-setup-deps] $*" >&2; exit 2; }

LOCK_DIR="" OUT="" IMAGE="" ALLOW_NETWORK=0
for arg in "$@"; do
  case "$arg" in
    --lockfile-dir=*) LOCK_DIR="${arg#*=}" ;;
    --out=*)          OUT="${arg#*=}" ;;
    --image=*)        IMAGE="${arg#*=}" ;;
    --allow-network)  ALLOW_NETWORK=1 ;;
    -h|--help)        sed -n '2,19p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "unknown argument: $arg" ;;
  esac
done

[[ "$ALLOW_NETWORK" == "1" ]] || die "refusing to run: pass --allow-network to acknowledge this trusted setup step reaches the package registry"
[[ -n "$LOCK_DIR" && -f "$LOCK_DIR/package.json" && -f "$LOCK_DIR/package-lock.json" ]] || die "--lockfile-dir must contain package.json and package-lock.json"
command -v docker >/dev/null 2>&1 || die "docker is required"
command -v jq >/dev/null 2>&1 || die "jq is required"
docker version --format '{{.Server.Version}}' >/dev/null 2>&1 || die "docker daemon is not reachable"
LOCK_DIR="$(cd "$LOCK_DIR" && pwd -P)"

if [[ -z "$IMAGE" ]]; then
  IMAGE="$(jq -r '.image.ref // empty' "$POLICY" 2>/dev/null)"
  [[ -n "$IMAGE" ]] || die "no pinned image in $POLICY; pass --image="
fi
if ! jq -e --arg image "$IMAGE" '.allowedImages // [] | index($image) != null' "$POLICY" >/dev/null 2>&1; then
  die "image '$IMAGE' is not in the atd-sandbox policy allowedImages"
fi
case "$IMAGE" in *@sha256:*) ;; *) die "image must be digest pinned (…@sha256:…)" ;; esac
docker image inspect "$IMAGE" >/dev/null 2>&1 || die "image $IMAGE is not present locally (this helper never pulls images)"

if command -v sha256sum >/dev/null 2>&1; then
  LOCK_SHA="$(sha256sum "$LOCK_DIR/package-lock.json" | cut -d' ' -f1)"
else
  LOCK_SHA="$(shasum -a 256 "$LOCK_DIR/package-lock.json" | cut -d' ' -f1)"
fi
STATE_BASE="${EVAL_STATE_DIR:-$HOME/.config/opencode/eval-harness}"
[[ -n "$OUT" ]] || OUT="$STATE_BASE/discovery/deps/$LOCK_SHA"
if [[ -e "$OUT" ]] && [[ -n "$(ls -A "$OUT" 2>/dev/null)" ]]; then
  die "snapshot destination already exists and is not empty: $OUT (snapshots are never overwritten)"
fi
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd -P)"
case "$OUT" in "$LOCK_DIR"|"$LOCK_DIR"/*) die "snapshot must live outside the lockfile directory" ;; esac

cp "$LOCK_DIR/package.json" "$OUT/package.json"
cp "$LOCK_DIR/package-lock.json" "$OUT/package-lock.json"

echo "[atd-setup-deps] trusted setup: npm ci --ignore-scripts in $IMAGE (network enabled for this step only)" >&2
docker run --rm --pull never \
  --read-only --cap-drop ALL --security-opt no-new-privileges \
  --pids-limit 512 --memory 2g --memory-swap 2g --cpus 2 \
  --user "$(id -u):$(id -g)" --workdir /snap \
  --tmpfs /tmp:rw,size=512m \
  -e HOME=/tmp -e npm_config_cache=/tmp/npm-cache -e npm_config_update_notifier=false -e CI=1 \
  -v "$OUT:/snap:rw" \
  "$IMAGE" npm ci --ignore-scripts --no-audit --no-fund >&2

[[ -d "$OUT/node_modules" ]] || die "npm ci did not produce node_modules"
NODE_VERSION="$(docker run --rm --pull never --network none --read-only --cap-drop ALL --security-opt no-new-privileges --user "$(id -u):$(id -g)" "$IMAGE" node --version 2>/dev/null || true)"
jq -n --arg lock "$LOCK_SHA" --arg image "$IMAGE" --arg node "$NODE_VERSION" --arg at "$(date -u +%FT%TZ)" \
  '{schema:"atd.deps-snapshot/v1",lockfileSha256:$lock,image:$image,nodeVersion:(if $node=="" then null else $node end),createdAt:$at,installCommand:"npm ci --ignore-scripts --no-audit --no-fund"}' > "$OUT/snapshot.json"
echo "$OUT"
