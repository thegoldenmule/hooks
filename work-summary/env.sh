#!/bin/bash
# Shared environment. launchd starts jobs with a minimal PATH and does not load
# nvm, so node and claude must be located explicitly or the 5:00 run dies with
# "command not found" and no summary appears.

# The install locates itself, so the checkout can live anywhere. Set
# GH_SUMMARY_DIR to keep the data somewhere other than beside the scripts.
DIR="${GH_SUMMARY_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
export DIR

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

# Prepend the newest nvm bin that carries both node and claude.
for d in $(ls -d "$HOME"/.nvm/versions/node/*/bin 2>/dev/null | sort -V -r); do
  if [ -x "$d/node" ] && [ -x "$d/claude" ]; then
    export PATH="$d:$PATH"
    break
  fi
done

# $1 title, $2 body. Passed as argv so quotes and newlines in the bullets
# cannot break the AppleScript. Notification Center truncates long bodies, so
# summary.md stays the authoritative copy.
notify() {
  /usr/bin/osascript - "$1" "$2" <<'APPLESCRIPT' >/dev/null 2>&1 || true
on run argv
  display notification (item 2 of argv) with title (item 1 of argv)
end run
APPLESCRIPT
}
