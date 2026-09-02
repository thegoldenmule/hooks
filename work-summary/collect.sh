#!/bin/bash
# Collects Benjamin's previous-day activity across the powerhouse-inc org using the
# real, authenticated gh CLI on macOS. Run by launchd weekday mornings at 5:00 AM.
# Output: latest.json, shaped by brief.mjs and summarized by summarize.sh.

set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

ORG="${GH_SUMMARY_ORG:-powerhouse-inc}"
OUT="$DIR/latest.json"
LOG="$DIR/collect.log"
ERRS="$DIR/.collect-errors"
LIMIT=100        # a 41-commit day is normal here, so 50 was one busy day from silently truncating
PR_CAP=40        # walking a PR's commits costs one API call each, so bound it
REF_CAP=40       # same for the branches a push event names
mkdir -p "$DIR"
: > "$ERRS"

# Previous calendar day. On Monday, reach back to Friday so the weekend is covered.
if [ "$(date +%u)" = "1" ]; then SPEC="-v-3d"; else SPEC="-v-1d"; fi
START=$(date $SPEC +%F)
END=$(date -v-1d +%F)
WINDOW="$START..$END"   # the label everything downstream displays

# GitHub's date qualifiers are UTC unless the value carries an offset, but
# "yesterday" has to mean yesterday *here*. Without the offset every commit and
# comment after 7pm CDT lands in the next UTC day and drops out of the window,
# which is how a full day on an open PR came back as a quiet day. Read the
# offset from the target days themselves so a DST boundary inside the window
# does not shift it.
SOFF=$(date $SPEC +%z)
EOFF=$(date -v-1d +%z)
isooff() { printf '%s:%s' "${1%??}" "${1#???}"; }   # -0500 -> -05:00
WSTART="${START}T00:00:00"
WEND="${END}T23:59:59"
RANGE="${WSTART}$(isooff "$SOFF")..${WEND}$(isooff "$EOFF")"
# Same bounds as epoch seconds, for filtering commit timestamps locally.
WSTART_EPOCH=$(date -j -f "%Y-%m-%dT%H:%M:%S%z" "${WSTART}${SOFF}" +%s)
WEND_EPOCH=$(date -j -f "%Y-%m-%dT%H:%M:%S%z" "${WEND}${EOFF}" +%s)

echo "=== $(date) collecting $WINDOW (as $RANGE) ===" >> "$LOG"

if ! command -v gh >/dev/null 2>&1; then
  echo '{"error":"gh not found on PATH"}' > "$OUT"; exit 1
fi
# gh keeps the token in the login keychain, which is the most likely thing to
# fail under launchd. Fail loudly rather than writing an empty summary.
if ! gh auth status >/dev/null 2>&1; then
  echo '{"error":"gh not authenticated (keychain unreachable?)"}' > "$OUT"; exit 1
fi

# A dropped connection used to come back as [] and read downstream as "nothing
# happened", so a reset socket became "no open PRs left over". Retry the
# transient cases, and when a query really is dead, name it in $ERRS so the
# brief reports a hole instead of an absence. $ERRS is a file because q runs
# inside a command substitution, where a shell variable would not survive.
q() {
  local name="$1"; shift
  local out
  for attempt in 1 2 3; do
    if out=$("$@" 2>>"$LOG"); then printf '%s' "$out"; return 0; fi
    echo "$(date '+%F %T') [collect] $name attempt $attempt failed" >> "$LOG"
    [ "$attempt" -lt 3 ] && sleep $((attempt * 3))
  done
  echo "$(date '+%F %T') [collect] $name GAVE UP, recording as missing" >> "$LOG"
  echo "$name" >> "$ERRS"
  echo '[]'
}

# A branch named by a push event can be gone by morning: the PR merged and the
# branch was deleted. Its commits are already covered by the merged-PR and
# default-branch queries, so a 404 is a quiet skip. Recording it as a failure
# instead stamped a complete day with "work may be missing". Anything other than
# a 404 keeps q's retry-and-report behaviour.
qref() {
  local name="$1"; shift
  local out err
  err=$(mktemp)
  for attempt in 1 2 3; do
    if out=$("$@" 2>"$err"); then rm -f "$err"; printf '%s' "$out"; return 0; fi
    cat "$err" >> "$LOG"
    if grep -q 'HTTP 404' "$err"; then
      echo "$(date '+%F %T') [collect] $name is gone, branch deleted, skipping" >> "$LOG"
      rm -f "$err"; echo '[]'; return 0
    fi
    echo "$(date '+%F %T') [collect] $name attempt $attempt failed" >> "$LOG"
    [ "$attempt" -lt 3 ] && sleep $((attempt * 3))
  done
  echo "$(date '+%F %T') [collect] $name GAVE UP, recording as missing" >> "$LOG"
  echo "$name" >> "$ERRS"
  rm -f "$err"
  echo '[]'
}

# Merge result sets that overlap, keeping one row per PR or issue.
union() { jq -s 'map(if type == "array" then . else [] end) | add | unique_by(.url)'; }

PR_FIELDS=number,title,repository,url,state,isDraft,updatedAt,createdAt

# `updated` alone only ever surfaces a PR on the day it was last touched, so a
# PR opened and worked all day shows up once, at the end, and is invisible on
# every day in between. Union it with `created` to catch the day it was opened.
PRS=$(printf '%s\n%s\n' \
  "$(q authored_prs_created gh search prs --author=@me --owner="$ORG" --created="$RANGE" --limit "$LIMIT" --json $PR_FIELDS)" \
  "$(q authored_prs_updated gh search prs --author=@me --owner="$ORG" --updated="$RANGE" --limit "$LIMIT" --json $PR_FIELDS)" \
  | union)

REVIEWED=$(q reviewed_prs gh search prs --reviewed-by=@me --owner="$ORG" --updated="$RANGE" \
        --limit "$LIMIT" --json number,title,repository,url,state,updatedAt)

ISSUES=$(printf '%s\n%s\n' \
  "$(q issues_created gh search issues --author=@me --owner="$ORG" --created="$RANGE" --limit "$LIMIT" --json number,title,repository,url,state,updatedAt)" \
  "$(q issues_updated gh search issues --author=@me --owner="$ORG" --updated="$RANGE" --limit "$LIMIT" --json number,title,repository,url,state,updatedAt)" \
  | union)

SEARCHED_COMMITS=$(q commits gh search commits --author=@me --owner="$ORG" --author-date="$RANGE" \
        --limit "$LIMIT" --json sha,repository,commit)

MERGED=$(q merged_prs gh search prs --author=@me --owner="$ORG" --merged-at="$RANGE" \
        --limit "$LIMIT" --json number,title,repository,url)

# `gh search commits` only indexes default branches, so a day spent entirely on
# a feature branch reports zero commits and the summary has nothing to describe
# but the merge. Walk the PRs found above and take their commits directly.
ME=$(gh api user --jq .login 2>>"$LOG")
BRANCH=$(
  if [ -z "$ME" ]; then
    echo "$(date '+%F %T') [collect] could not resolve own login, skipping branch commits" >> "$LOG"
    echo "branch_commits" >> "$ERRS"
    echo '[]'
  else
    n=0
    printf '%s\n%s\n' "$PRS" "$MERGED" \
      | jq -s -r 'map(if type == "array" then . else [] end) | add | unique_by(.url)
                  | .[] | "\(.repository.nameWithOwner)\t\(.number)"' \
      | while IFS=$'\t' read -r repo num; do
          [ -n "${repo:-}" ] && [ -n "${num:-}" ] || continue
          n=$((n + 1))
          if [ "$n" -gt "$PR_CAP" ]; then
            echo "$(date '+%F %T') [collect] more than $PR_CAP PRs, stopped walking commits" >> "$LOG"
            echo "branch_commits_capped" >> "$ERRS"
            break
          fi
          q "pr_commits:$repo#$num" gh pr view "$num" --repo "$repo" --json commits \
            | jq -c --arg repo "$repo" --arg me "$ME" \
                   --argjson s "$WSTART_EPOCH" --argjson e "$WEND_EPOCH" '
                (if type == "object" then .commits else [] end) // [] | [ .[]
                  | select(any(.authors[]?; .login == $me))
                  | select((.authoredDate | fromdateiso8601) >= $s
                       and (.authoredDate | fromdateiso8601) <= $e)
                  | { sha: .oid,
                      repository: { nameWithOwner: $repo, fullName: $repo,
                                    name: ($repo | split("/") | last) },
                      commit: { message: (.messageHeadline
                                  + (if (.messageBody // "") == "" then "" else "\n\n" + .messageBody end)),
                                author: { date: .authoredDate,
                                          name: (.authors[0].name // ""),
                                          email: (.authors[0].email // "") } } } ]'
        done | jq -s 'add // []'
  fi
)

# A PR is not the only way work reaches GitHub, and until this it was the only
# way work reached this summary. `gh search commits` indexes default branches
# only, and the walk above can only see a branch that already has a PR, so a day
# spent committing to a branch before opening the PR collected three commits out
# of thirty-two. Push events name every branch pushed, PR or no PR.
#
# The event window starts with the summary window but runs to now, because a
# branch committed at 11pm and pushed the next morning is still that day's work.
# Author date, filtered below, decides which day a commit belongs to.
PUSHED=$(
  if [ -z "$ME" ]; then
    echo '[]'
  else
    n=0
    q push_events gh api --paginate "/users/$ME/events?per_page=100" \
      | jq -s -r --arg org "$ORG" --argjson s "$WSTART_EPOCH" '
          [ .[] | if type == "array" then .[] else empty end ]
          | map(select(.type == "PushEvent"))
          | map(select(.repo.name | startswith($org + "/")))
          | map(select(.payload.ref | startswith("refs/heads/")))
          | map(select((.created_at | fromdateiso8601) >= $s))
          | map("\(.repo.name)\t\(.payload.ref)")
          | unique | .[]' \
      | while IFS=$'\t' read -r repo ref; do
          [ -n "${repo:-}" ] && [ -n "${ref:-}" ] || continue
          n=$((n + 1))
          if [ "$n" -gt "$REF_CAP" ]; then
            echo "$(date '+%F %T') [collect] more than $REF_CAP pushed refs, stopped" >> "$LOG"
            echo "pushed_ref_commits_capped" >> "$ERRS"
            break
          fi
          # `since` filters on committer date, which a rebase moves forward but
          # never back, so it is safe as a cheap bound. `until` is not: a
          # rebased commit can be committed after the window it was authored in.
          # Author date decides, and jq applies it.
          #
          # --paginate because a 41-commit day is normal here and a Monday
          # window covers three of them, so one page is a busy weekend away from
          # dropping commits with nothing to say it did. jq filters each page and
          # the add below merges them.
          qref "ref_commits:$repo@$ref" gh api --paginate \
            "repos/$repo/commits?sha=${ref#refs/heads/}&author=$ME&since=$(date -r "$WSTART_EPOCH" -u +%FT%TZ)&per_page=$LIMIT" \
            | jq -c --arg repo "$repo" \
                   --argjson s "$WSTART_EPOCH" --argjson e "$WEND_EPOCH" '
                (if type == "array" then . else [] end) | [ .[]
                  | select((.commit.author.date | fromdateiso8601) >= $s
                       and (.commit.author.date | fromdateiso8601) <= $e)
                  | { sha: .sha,
                      repository: { nameWithOwner: $repo, fullName: $repo,
                                    name: ($repo | split("/") | last) },
                      commit: { message: .commit.message,
                                author: { date: .commit.author.date,
                                          name: (.commit.author.name // ""),
                                          email: (.commit.author.email // "") } } } ]'
        done | jq -s 'add // []'
  fi
)

# The squash commit for a merged PR and that PR's own branch commits both
# describe the same work. Keeping both is what we want, since brief.mjs folds
# the squash into the PR entry, but the same sha must not appear twice.
COMMITS=$(printf '%s\n%s\n%s\n' "$SEARCHED_COMMITS" "$BRANCH" "$PUSHED" \
  | jq -s 'map(if type == "array" then . else [] end) | add | unique_by(.sha)')

# Any query that comes back exactly at the cap probably lost rows. Say so in the
# output so the summary can admit it rather than quietly under-reporting.
TRUNCATED=$(
  for pair in "authored_prs:$PRS" "reviewed_prs:$REVIEWED" "issues:$ISSUES" \
              "commits:$SEARCHED_COMMITS" "merged_prs:$MERGED"; do
    name="${pair%%:*}"; body="${pair#*:}"
    n=$(printf '%s' "$body" | jq 'length' 2>/dev/null || echo 0)
    [ "$n" -ge "$LIMIT" ] && echo "$name"
  done | jq -R . | jq -s .
)
FAILED=$(sort -u "$ERRS" | jq -R . | jq -s .)

cat > "$OUT" <<JSON
{
  "generated_at": "$(date -u +%FT%TZ)",
  "window": "$WINDOW",
  "window_query": "$RANGE",
  "org": "$ORG",
  "limit": $LIMIT,
  "truncated": $TRUNCATED,
  "failed_queries": $FAILED,
  "authored_prs": $PRS,
  "merged_prs": $MERGED,
  "reviewed_prs": $REVIEWED,
  "issues": $ISSUES,
  "commits": $COMMITS
}
JSON

if ! jq -e . "$OUT" >/dev/null 2>&1; then
  echo "$(date '+%F %T') [collect] wrote malformed JSON" >> "$LOG"
  echo '{"error":"collector produced malformed JSON, see collect.log"}' > "$OUT"
  exit 1
fi

echo "wrote $OUT ($(wc -c < "$OUT") bytes, $(printf '%s' "$COMMITS" | jq length) commits, failed: $(printf '%s' "$FAILED" | jq -c .))" >> "$LOG"
