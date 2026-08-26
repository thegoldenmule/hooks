#!/bin/bash
# End-to-end check: feed the status line synthetic Claude Code payloads, assert
# the rendered text and the color it picked.
set -u

LINE="$(cd "$(dirname "$0")" && pwd)/statusline.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A repo of our own, so the git cases don't depend on this checkout's branch.
REPO="$WORK/sample-repo"
mkdir -p "$REPO/nested"
git -C "$REPO" init -q -b trunk
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m first
PLAIN="$WORK/not-a-repo"
mkdir -p "$PLAIN"

fail=0

# render <dir> <percent-json> -> status line, ANSI escapes intact
render() {
  printf '{"workspace":{"current_dir":"%s"},"context_window":{"used_percentage":%s}}' "$1" "$2" |
    "$LINE"
}

strip_ansi() { sed $'s/\033\[[0-9;]*m//g'; }

check() {
  local label="$1" want="$2" got="$3"
  if [ "$got" = "$want" ]; then
    printf 'ok    %s\n' "$label"
  else
    printf 'FAIL  %s\n        want: %s\n        got:  %s\n' "$label" "$want" "$got"
    fail=1
  fi
}

# --- what it says ----------------------------------------------------------
check 'repo and branch' \
  '[sample-repo] (trunk)  [██████░░░░░░░░░░░░░░] 33%' \
  "$(render "$REPO" 33 | strip_ansi)"

check 'branch found from a subdirectory' \
  '[sample-repo] (trunk)  [░░░░░░░░░░░░░░░░░░░░] 0%' \
  "$(render "$REPO/nested" 0 | strip_ansi)"

check 'outside a repo, no branch' \
  '[not-a-repo]  [██░░░░░░░░░░░░░░░░░░] 10%' \
  "$(render "$PLAIN" 10 | strip_ansi)"

check 'detached HEAD shows the short sha' \
  "[sample-repo] ($(git -C "$REPO" rev-parse --short HEAD))" \
  "$(git -C "$REPO" checkout -q --detach && render "$REPO" 0 | strip_ansi | cut -d' ' -f1-2)"
git -C "$REPO" checkout -q trunk

check 'bar fills' \
  '[sample-repo] (trunk)  [████████████████████] 100%' \
  "$(render "$REPO" 100 | strip_ansi)"

# --- percentages it is handed ----------------------------------------------
percent() { render "$REPO" "$1" | strip_ansi | sed 's/.* //'; }

check 'fraction rounds to a whole number' '42%' "$(percent 41.6)"
check 'above 100 clamps'                  '100%' "$(percent 140)"
check 'below zero clamps'                 '0%'   "$(percent -5)"
check 'missing field reads as zero' '0%' \
  "$(printf '{}' | "$LINE" | strip_ansi | sed 's/.* //')"

# --- the color it picked ---------------------------------------------------
# 32 green, 33 yellow, 31 red. Checked either side of both thresholds.
color_of_bar() { render "$REPO" "$1" | sed $'s/.*\033\[2;\\([0-9]*\\)m\\[[█░]*\\].*/\\1/'; }

check 'at the yellow threshold, still green' '32' "$(color_of_bar 50)"
check 'past it, yellow'                      '33' "$(color_of_bar 51)"
check 'at the red threshold, still yellow'   '33' "$(color_of_bar 75)"
check 'past it, red'                         '31' "$(color_of_bar 76)"

exit "$fail"
