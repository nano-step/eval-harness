#!/usr/bin/env bash
set -euo pipefail

STORE="${NANO_BRAIN_SHIM_STORE:-./nano-brain-store.json}"

if [[ ! -s "$STORE" ]]; then
  echo '{"writes":[],"queries":[]}' > "$STORE"
fi

cmd="${1:-}"
shift || true

record_call() {
  local bucket="$1"
  local payload="$2"
  jq --arg k "$bucket" --argjson p "$payload" \
    '.[$k] += [$p]' "$STORE" > "$STORE.tmp" && mv "$STORE.tmp" "$STORE"
}

case "$cmd" in
  nano-brain)
    sub="${1:-}"
    shift || true
    case "$sub" in
      write)
        content=""
        collection=""
        tags_csv=""
        while [[ $# -gt 0 ]]; do
          case "$1" in
            -c|--collection) collection="$2"; shift 2 ;;
            --tags) tags_csv="$2"; shift 2 ;;
            --content) content="$2"; shift 2 ;;
            *) shift ;;
          esac
        done
        payload=$(jq -n \
          --arg content "$content" \
          --arg collection "$collection" \
          --arg tags "$tags_csv" \
          '{content:$content, collection:$collection, tags:($tags|split(",")|map(select(length>0)))}')
        record_call writes "$payload"
        echo '{"ok":true,"id":"shim-'$(date +%s%N)'"}'
        ;;
      query)
        query_text=""
        collection=""
        n=5
        while [[ $# -gt 0 ]]; do
          case "$1" in
            -c|--collection) collection="$2"; shift 2 ;;
            -n) n="$2"; shift 2 ;;
            --json) shift ;;
            -*) shift ;;
            *) [[ -z "$query_text" ]] && query_text="$1"; shift ;;
          esac
        done
        payload=$(jq -n \
          --arg q "$query_text" \
          --arg coll "$collection" \
          --argjson n "$n" \
          '{query:$q, collection:$coll, n:$n}')
        record_call queries "$payload"
        echo '{"results":[]}'
        ;;
      *)
        echo "shim: unknown nano-brain subcommand: $sub" >&2
        exit 1
        ;;
    esac
    ;;
  *)
    echo "shim: pass-through for: $cmd $*" >&2
    exit 1
    ;;
esac
