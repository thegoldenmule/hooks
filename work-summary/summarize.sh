#!/bin/bash
# brief -> claude -> validator -> summary.md, history.md, notification.
# The validator is the authority on format; the model gets up to MAX_TRIES
# attempts, each one fed the previous failure verbatim.

set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"
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

if ! node brief.mjs >> "$LOG" 2>&1; then
  say "FATAL: brief.mjs failed"
  printf 'shaping FAILED %s\n\nCould not shape the collected data. See collect.log.\n' \
    "$(date '+%F %T')" > summary.md
  notify "Work summary failed" "Could not shape the collected data. See collect.log."
  exit 1
fi

WINDOW=$(node -e 'console.log(JSON.parse(require("fs").readFileSync("brief.json","utf8")).window||"?")')

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

FEEDBACK=""
PASSED=0
for try in $(seq 1 "$MAX_TRIES"); do
  {
    cat prompt.md
    cat brief.txt
    if [ -n "$FEEDBACK" ]; then
      printf '\nYOUR PREVIOUS ATTEMPT:\n\n%s\n' "$(cat draft.md)"
      printf '\nTHE VALIDATOR REJECTED IT:\n\n%s\n' "$FEEDBACK"
      printf '\nFix every problem listed and output the corrected bullets only.\n'
    fi
  } > request.txt

  # </dev/null or claude stalls 3s waiting on stdin it will never get.
  if ! claude -p "$(cat request.txt)" > draft.raw 2>>"$LOG" < /dev/null; then
    say "attempt $try: claude invocation failed"
    continue
  fi
  # Strip any code fence the model wraps around the list.
  sed 's/^```.*$//' draft.raw | sed '/^$/d' > draft.md

  if FEEDBACK=$(node validate.mjs draft.md 2>>"$LOG"); then
    say "attempt $try: $FEEDBACK"
    PASSED=1
    break
  fi
  say "attempt $try: rejected, $(head -1 <<<"$FEEDBACK")"
done

BULLETS=$(cat draft.md)

if [ "$PASSED" = "1" ]; then
  printf '%s\n\n%s\n' "$WINDOW" "$BULLETS" > summary.md
else
  say "FATAL: no draft passed in $MAX_TRIES attempts"
  {
    printf '%s\n\n%s\n\nNEEDS ATTENTION: no draft passed the validator in %s attempts.\n' \
      "$WINDOW" "$BULLETS" "$MAX_TRIES"
    printf 'Last validator report:\n\n%s\n' "$FEEDBACK"
  } > summary.md
fi

# Replace any existing section for this window so a manual re-run corrects the
# day's entry instead of stacking a duplicate onto it.
if [ -f history.md ]; then
  # cat -s collapses the blank lines a removed section leaves behind, and the
  # sed drops any that ended up at the top of the file.
  awk -v w="## $WINDOW" '$0 == w { skip = 1; next } /^## / { skip = 0 } !skip' \
    history.md | cat -s | sed '/./,$!d' > history.tmp && mv history.tmp history.md
fi
{ printf '\n## %s\n\n%s\n' "$WINDOW" "$BULLETS"; } >> history.md
# The leading newline is a separator between sections, but it leaves a stray
# blank line at the top of a fresh file.
sed -i '' '/./,$!d' history.md

if [ "$PASSED" = "1" ]; then
  notify "Work summary $WINDOW" "$BULLETS"
else
  notify "Work summary $WINDOW (needs attention)" "The draft failed the format check. See summary.md."
fi
exit 0
