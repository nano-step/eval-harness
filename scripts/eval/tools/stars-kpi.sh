#!/usr/bin/env bash
set -euo pipefail

REPO="${EVAL_HARNESS_REPO:-nano-step/eval-harness}"
HISTORY_FILE="${EVAL_HARNESS_KPI_FILE:-$HOME/.eval-harness/kpi-history.ndjson}"

mkdir -p "$(dirname "$HISTORY_FILE")"

if ! command -v gh >/dev/null 2>&1; then
  echo "error: gh CLI not on PATH" >&2; exit 64
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq not on PATH" >&2; exit 64
fi

ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

repo_json=$(gh api "repos/${REPO}" --jq '{
  stars: .stargazers_count,
  forks: .forks_count,
  watchers: .subscribers_count,
  issues: .open_issues_count
}')

views_14d=$(gh api "repos/${REPO}/traffic/views" --jq '{
  count: .count,
  uniques: .uniques
}' 2>/dev/null || echo '{"count":null,"uniques":null}')

clones_14d=$(gh api "repos/${REPO}/traffic/clones" --jq '{
  count: .count,
  uniques: .uniques
}' 2>/dev/null || echo '{"count":null,"uniques":null}')

referrers=$(gh api "repos/${REPO}/traffic/popular/referrers" --jq '[.[0:5][] | {referrer:.referrer, count:.count, uniques:.uniques}]' 2>/dev/null || echo '[]')

paths=$(gh api "repos/${REPO}/traffic/popular/paths" --jq '[.[0:5][] | {path:.path, count:.count, uniques:.uniques}]' 2>/dev/null || echo '[]')

contributors_count=$(gh api "repos/${REPO}/contributors?per_page=100" --jq 'length' 2>/dev/null || echo 0)

unique_pr_authors_30d=$(gh pr list -R "$REPO" --state all --limit 200 \
  --json author,createdAt \
  --jq "[.[] | select(.createdAt > \"$(date -u -d '30 days ago' +%Y-%m-%d 2>/dev/null || date -u -v-30d +%Y-%m-%d)\") | .author.login] | unique | length" 2>/dev/null || echo 0)

unique_issue_authors_30d=$(gh issue list -R "$REPO" --state all --limit 200 \
  --json author,createdAt \
  --jq "[.[] | select(.createdAt > \"$(date -u -d '30 days ago' +%Y-%m-%d 2>/dev/null || date -u -v-30d +%Y-%m-%d)\") | .author.login] | unique | length" 2>/dev/null || echo 0)

snapshot=$(jq -nc \
  --arg ts "$ts" \
  --arg repo "$REPO" \
  --argjson r "$repo_json" \
  --argjson v "$views_14d" \
  --argjson c "$clones_14d" \
  --argjson ref "$referrers" \
  --argjson p "$paths" \
  --argjson contribs "$contributors_count" \
  --argjson pr_authors "$unique_pr_authors_30d" \
  --argjson iss_authors "$unique_issue_authors_30d" \
  '{
    timestamp: $ts,
    repo: $repo,
    stars: $r.stars,
    forks: $r.forks,
    watchers: $r.watchers,
    open_issues: $r.issues,
    contributors_total: $contribs,
    unique_pr_authors_30d: $pr_authors,
    unique_issue_authors_30d: $iss_authors,
    views_14d: $v,
    clones_14d: $c,
    top_referrers: $ref,
    top_paths: $p
  }')

echo "$snapshot" >> "$HISTORY_FILE"

prev=$(grep -v "^$" "$HISTORY_FILE" | tail -2 | head -1 2>/dev/null || echo '{}')
prev_stars=$(echo "$prev" | jq -r '.stars // 0')
cur_stars=$(echo "$snapshot" | jq -r '.stars')
delta_stars=$((cur_stars - prev_stars))

echo ""
echo "═══════════════════════════════════════════════════════════════════"
echo "  eval-harness KPI snapshot — $ts"
echo "═══════════════════════════════════════════════════════════════════"
echo "$snapshot" | jq -r '
  "  Stars:            \(.stars)" +
  "\n  Forks:            \(.forks)" +
  "\n  Watchers:         \(.watchers)" +
  "\n  Open issues:      \(.open_issues)" +
  "\n  Contributors:     \(.contributors_total)" +
  "\n  PR authors (30d): \(.unique_pr_authors_30d)" +
  "\n  Issue authors (30d): \(.unique_issue_authors_30d)" +
  "\n  Views (14d):      \(.views_14d.count) total, \(.views_14d.uniques) unique" +
  "\n  Clones (14d):     \(.clones_14d.count) total, \(.clones_14d.uniques) unique"
'
if [[ "$delta_stars" -ne 0 ]]; then
  if [[ "$delta_stars" -gt 0 ]]; then
    printf "\n  ★ Stars delta:    +%d since previous snapshot\n" "$delta_stars"
  else
    printf "\n  ★ Stars delta:    %d since previous snapshot\n" "$delta_stars"
  fi
fi

echo ""
echo "  Top referrers (14d):"
echo "$snapshot" | jq -r '.top_referrers[] | "    \(.referrer)  —  \(.count) views, \(.uniques) unique"' 2>/dev/null || echo "    (no traffic data)"

echo ""
echo "  Top paths (14d):"
echo "$snapshot" | jq -r '.top_paths[] | "    \(.path)  —  \(.count) views, \(.uniques) unique"' 2>/dev/null || echo "    (no traffic data)"

echo ""
echo "  Star milestones for awesome-list PRs:"
echo "$snapshot" | jq -r '
  if .stars >= 500 then "    ✓ Hannibal046/Awesome-LLM     — ready (≥500)"
  else "    □ Hannibal046/Awesome-LLM     — \(500 - .stars) more stars needed (target ≥500)"
  end,
  if .stars >= 200 then "    ✓ tensorchord/Awesome-LLMOps  — ready (≥200, PR already open #538)"
  else "    □ tensorchord/Awesome-LLMOps  — \(200 - .stars) more stars (PR already open #538)"
  end,
  if .stars >= 500 then "    ✓ visenger/awesome-mlops      — ready (≥500), but list is dead — skip"
  else "    □ visenger/awesome-mlops      — list is dead, skip regardless"
  end,
  if .stars >= 200 then "    ✓ alebcay/awesome-shell       — ready (≥200)"
  else "    □ alebcay/awesome-shell       — \(200 - .stars) more stars needed"
  end
'

echo ""
echo "  History file: $HISTORY_FILE ($(wc -l < "$HISTORY_FILE") snapshots)"
echo "═══════════════════════════════════════════════════════════════════"
