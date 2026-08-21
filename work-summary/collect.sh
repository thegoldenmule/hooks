#!/bin/bash
# Collects Benjamin's previous-day activity across the powerhouse-inc org using the
# real, authenticated gh CLI on macOS. Run by launchd weekday mornings at 7:55 AM.
# Output: latest.json, shaped by brief.mjs and summarized by summarize.sh.

set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

ORG="${GH_SUMMARY_ORG:-powerhouse-inc}"
OUT="$DIR/latest.json"
LOG="$DIR/collect.log"
LIMIT=100   # a 41-commit day is normal here, so 50 was one busy day from silently truncating
mkdir -p "$DIR"

# Previous calendar day. On Monday, reach back to Friday so the weekend is covered.
if [ "$(date +%u)" = "1" ]; then
  START=$(date -v-3d +%F)
else
  START=$(date -v-1d +%F)
fi
END=$(date -v-1d +%F)
RANGE="$START..$END"

echo "=== $(date) collecting $RANGE ===" >> "$LOG"

if ! command -v gh >/dev/null 2>&1; then
  echo '{"error":"gh not found on PATH"}' > "$OUT"; exit 1
fi
# gh keeps the token in the login keychain, which is the most likely thing to
# fail under launchd. Fail loudly rather than writing an empty summary.
if ! gh auth status >/dev/null 2>&1; then
  echo '{"error":"gh not authenticated (keychain unreachable?)"}' > "$OUT"; exit 1
fi

q() { "$@" 2>>"$LOG" || echo '[]'; }

PRS=$(q gh search prs --author=@me --owner="$ORG" --updated="$RANGE" \
        --limit "$LIMIT" --json number,title,repository,url,state,isDraft,updatedAt)

REVIEWED=$(q gh search prs --reviewed-by=@me --owner="$ORG" --updated="$RANGE" \
        --limit "$LIMIT" --json number,title,repository,url,state,updatedAt)

ISSUES=$(q gh search issues --author=@me --owner="$ORG" --updated="$RANGE" \
        --limit "$LIMIT" --json number,title,repository,url,state,updatedAt)

COMMITS=$(q gh search commits --author=@me --owner="$ORG" --author-date="$RANGE" \
        --limit "$LIMIT" --json sha,repository,commit)

MERGED=$(q gh search prs --author=@me --owner="$ORG" --merged-at="$RANGE" \
        --limit "$LIMIT" --json number,title,repository,url)

# Any query that comes back exactly at the cap probably lost rows. Say so in the
# output so the summary can admit it rather than quietly under-reporting.
TRUNCATED=$(
  for pair in "authored_prs:$PRS" "reviewed_prs:$REVIEWED" "issues:$ISSUES" \
              "commits:$COMMITS" "merged_prs:$MERGED"; do
    name="${pair%%:*}"; body="${pair#*:}"
    n=$(printf '%s' "$body" | jq 'length' 2>/dev/null || echo 0)
    [ "$n" -ge "$LIMIT" ] && echo "$name"
  done | jq -R . | jq -s .
)

cat > "$OUT" <<JSON
{
  "generated_at": "$(date -u +%FT%TZ)",
  "window": "$RANGE",
  "org": "$ORG",
  "limit": $LIMIT,
  "truncated": $TRUNCATED,
  "authored_prs": $PRS,
  "merged_prs": $MERGED,
  "reviewed_prs": $REVIEWED,
  "issues": $ISSUES,
  "commits": $COMMITS
}
JSON

echo "wrote $OUT ($(wc -c < "$OUT") bytes)" >> "$LOG"
