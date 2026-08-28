#!/bin/bash
# Prints the day's bullets the first time an interactive shell opens after a new
# summary is written.
#
# Notification Center will not display osascript notifications on this machine:
# they are attributed to Script Editor, whose ncprefs flags have the suppress
# bit set, so the banner is dropped with no error. The terminal is the delivery
# path instead. It needs no permission and cannot be suppressed.

set -uo pipefail

DIR="${GH_SUMMARY_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
S="$DIR/summary.md"
MARK="$DIR/.shown"

[ -f "$S" ] || exit 0

# Once per new summary, not once per shell, so opening five tabs does not print
# five times.
stamp=$(stat -f %m "$S" 2>/dev/null) || exit 0
if [ "${1:-}" != "--force" ]; then
  [ -f "$MARK" ] && [ "$(cat "$MARK" 2>/dev/null)" = "$stamp" ] && exit 0
fi

if [ -t 1 ]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; WARN=$'\033[1;33m'; OFF=$'\033[0m'
else
  BOLD=""; DIM=""; WARN=""; OFF=""
fi

WINDOW=$(head -1 "$S")
printf '\n%sWork log%s %s%s%s\n' "$BOLD" "$OFF" "$DIM" "$WINDOW" "$OFF"
bullets=$(grep '^- ' "$S" || true)
if [ -n "$bullets" ]; then
  printf '%s\n' "$bullets" | sed "s/^/  /"
else
  # A failed run has no bullets, so show its explanation instead of nothing.
  # The NEEDS ATTENTION line is dropped here because it is reprinted below in
  # the warning colour; leaving it in showed the same sentence twice.
  tail -n +2 "$S" | grep -v '^NEEDS ATTENTION:' | cat -s | sed '/./,$!d' | sed "s/^/  /"
fi
# Every pattern here is anchored to the start of a line, and none is matched
# case-insensitively, because these are sentinels written by run.sh and
# summarize.sh rather than words. A bare `grep -i failed` also matches a bullet
# describing a day's work on a failed-job rollback, which flags a clean run as
# broken and teaches you to ignore the warning.
# summarize.sh writes the reason into the NEEDS ATTENTION line itself. This
# used to hardcode "the draft failed the format check", which is only one of
# the ways a run fails: it also printed that when the model was never reached
# at all and no draft existed to fail anything.
attention=$(sed -n 's/^NEEDS ATTENTION: *//p' "$S" | head -1)
if [ -n "$attention" ]; then
  printf '%s  %s, see summary.md%s\n' "$WARN" "${attention%.}" "$OFF"
elif grep -q "^INCOMPLETE:" "$S"; then
  printf '%s  some queries failed, so this day may be under-reported%s\n' "$WARN" "$OFF"
elif grep -qE "^(collection|shaping) FAILED|^collection INCOMPLETE" "$S"; then
  printf '%s  this run did not complete, check collect.log%s\n' "$WARN" "$OFF"
fi
printf '%s  %s%s\n\n' "$DIM" "$S" "$OFF"

printf '%s' "$stamp" > "$MARK"
