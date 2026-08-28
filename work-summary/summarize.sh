#!/bin/bash
# brief -> claude -> validator -> summary.md, history.md, notification.
# The validator is the authority on format; the model gets up to MAX_TRIES
# attempts, each one fed the previous failure verbatim.

set -uo pipefail
SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SELF/env.sh"
# Data lives in $DIR, which GH_SUMMARY_DIR can move; the scripts and the prompt
# always come from beside this file. Reading them out of $DIR meant setting
# GH_SUMMARY_DIR broke the run.
cd "$DIR" || exit 1

LOG="$DIR/collect.log"
MAX_TRIES=4
say() { echo "$(date '+%F %T') [summarize] $*" >> "$LOG"; }

for bin in node claude; do
  command -v "$bin" >/dev/null 2>&1 || {
    say "FATAL: $bin not found on PATH ($PATH)"
    notify "Work summary failed" "$bin is not on the PATH launchd provides."
    exit 1
  }
done

if ! node "$SELF/brief.mjs" >> "$LOG" 2>&1; then
  say "FATAL: brief.mjs failed"
  printf 'shaping FAILED %s\n\nCould not shape the collected data. See collect.log.\n' \
    "$(date '+%F %T')" > summary.md
  notify "Work summary failed" "Could not shape the collected data. See collect.log."
  exit 1
fi

WINDOW=$(node -e 'console.log(JSON.parse(require("fs").readFileSync("brief.json","utf8")).window||"?")')
FAILED=$(node -e 'console.log((JSON.parse(require("fs").readFileSync("brief.json","utf8")).failed_queries||[]).join(", "))')

# A collection that lost queries and found nothing has no answer to give. Saying
# so is the whole fix: the old code called this a quiet day.
if grep -q "^COLLECTION INCOMPLETE" brief.txt; then
  {
    printf '%s\n\n' "$WINDOW"
    printf 'collection INCOMPLETE, nothing usable found.\n\n'
    printf 'These queries failed: %s\n' "$FAILED"
    printf 'This is not a quiet day, it is a run that could not see. Check collect.log.\n'
  } > summary.md
  notify "Work summary $WINDOW (incomplete)" "Queries failed: $FAILED"
  say "INCOMPLETE in $WINDOW, failed: $FAILED"
  exit 1
fi

# A genuinely empty window is a real answer, not a failure.
if grep -q "^NO ACTIVITY FOUND" brief.txt; then
  printf '%s\n\n- I did not push anything to the powerhouse org in this window.\n' "$WINDOW" > summary.md
  if [ -f history.md ]; then
    awk -v w="## $WINDOW" '$0 == w { skip = 1; next } /^## / { skip = 0 } !skip' \
      history.md | cat -s | sed '/./,$!d' > history.tmp && mv history.tmp history.md
  fi
  { printf '\n## %s\n\n' "$WINDOW"; tail -n +3 summary.md; } >> history.md
  notify "Work summary $WINDOW" "No activity found in this window."
  say "no activity in $WINDOW"
  exit 0
fi

# A previous run's draft.md is still on disk. If every attempt below fails to
# reach the model, reading that file would publish yesterday's bullets under
# today's window, which is how a stale day got copied into history.md.
rm -f draft.md draft.raw

FEEDBACK=""
INVOKE_ERR=""
PASSED=0
GOT_DRAFT=0
TRIES=0
for try in $(seq 1 "$MAX_TRIES"); do
  TRIES=$try
  {
    cat "$SELF/prompt.md"
    cat brief.txt
    if [ -n "$FEEDBACK" ]; then
      printf '\nYOUR PREVIOUS ATTEMPT:\n\n%s\n' "$(cat draft.md)"
      printf '\nTHE VALIDATOR REJECTED IT:\n\n%s\n' "$FEEDBACK"
      printf '\nFix every problem listed and output the corrected bullets only.\n'
    fi
  } > request.txt

  # </dev/null or claude stalls 3s waiting on stdin it will never get.
  if ! claude -p "$(cat request.txt)" > draft.raw 2>>"$LOG" < /dev/null; then
    # claude prints its reason on stdout, so draft.raw holds the error rather
    # than a draft. Keep it: it is the only place the real cause survives.
    INVOKE_ERR=$(head -c 500 draft.raw)
    say "attempt $try: claude invocation failed, ${INVOKE_ERR:-no output}"
    # An expired login fails identically four times in a row. Retrying it just
    # delays the report by six minutes and buries the one useful message.
    if grep -qiE 'authenticat|oauth|credential|logged out|log in' draft.raw; then
      say "not retrying: this needs a login, not another attempt"
      break
    fi
    continue
  fi
  # Strip any code fence the model wraps around the list.
  sed 's/^```.*$//' draft.raw | sed '/^$/d' > draft.md
  GOT_DRAFT=1
  INVOKE_ERR=""

  if FEEDBACK=$(node "$SELF/validate.mjs" draft.md 2>>"$LOG"); then
    say "attempt $try: $FEEDBACK"
    PASSED=1
    break
  fi
  say "attempt $try: rejected, $(head -1 <<<"$FEEDBACK")"
done

# Only ever the bullets this run produced. No draft means no bullets, not the
# last run's.
BULLETS=""
[ "$GOT_DRAFT" = "1" ] && BULLETS=$(cat draft.md)

# The NEEDS ATTENTION line carries its own reason, because two different things
# go wrong here and calling both of them a format failure sent a real morning
# looking for a bad draft that had never been written.
if [ "$PASSED" = "1" ]; then
  printf '%s\n\n%s\n' "$WINDOW" "$BULLETS" > summary.md
  # Partial data still produces bullets, but they describe a floor. Mark it so
  # the terminal says the day may be under-reported.
  if [ -n "$FAILED" ]; then
    printf '\nINCOMPLETE: these queries failed, so work may be missing: %s\n' "$FAILED" >> summary.md
  fi
  ATTENTION=""
elif [ "$GOT_DRAFT" = "0" ]; then
  say "FATAL: claude never returned a draft in $TRIES attempt(s)"
  ATTENTION="could not reach the model, so there are no bullets for this window"
  {
    printf '%s\n\nNEEDS ATTENTION: %s.\n\n' "$WINDOW" "$ATTENTION"
    printf 'Last error from claude:\n\n%s\n' "${INVOKE_ERR:-claude exited non-zero with no output}"
  } > summary.md
else
  say "FATAL: no draft passed the validator in $TRIES attempt(s)"
  ATTENTION="no draft passed the format check in $TRIES attempts"
  {
    printf '%s\n\n%s\n\nNEEDS ATTENTION: %s.\n' "$WINDOW" "$BULLETS" "$ATTENTION"
    printf 'Last validator report:\n\n%s\n' "$FEEDBACK"
  } > summary.md
fi

# A run that produced no bullets has nothing to record. Leaving history.md
# alone also preserves whatever a previous good run wrote for this window,
# rather than replacing a real day with an empty section.
# An empty draft counts as no draft here: replacing a good section with a bare
# marker would lose the day rather than preserve it.
if [ "$GOT_DRAFT" = "1" ] && [ -n "$BULLETS" ]; then
  # Replace any existing section for this window so a manual re-run corrects the
  # day's entry instead of stacking a duplicate onto it.
  if [ -f history.md ]; then
    # cat -s collapses the blank lines a removed section leaves behind, and the
    # sed drops any that ended up at the top of the file.
    awk -v w="## $WINDOW" '$0 == w { skip = 1; next } /^## / { skip = 0 } !skip' \
      history.md | cat -s | sed '/./,$!d' > history.tmp && mv history.tmp history.md
  fi
  {
    printf '\n## %s\n\n' "$WINDOW"
    # Keep a rejected draft, because the content is usually fine and only the
    # shape is wrong, but never let it sit in the record looking checked.
    [ "$PASSED" = "1" ] || printf '(this draft did not pass the format check)\n\n'
    printf '%s\n' "$BULLETS"
  } >> history.md
  # The leading newline is a separator between sections, but it doubles up on
  # the blank a removed section left behind, and it leaves a stray blank line
  # at the top of a fresh file. cat -s takes the first, sed the second.
  cat -s history.md | sed '/./,$!d' > history.tmp && mv history.tmp history.md
fi

if [ "$PASSED" = "1" ]; then
  notify "Work summary $WINDOW" "$BULLETS"
else
  notify "Work summary $WINDOW (needs attention)" "$ATTENTION. See summary.md."
fi
exit 0
