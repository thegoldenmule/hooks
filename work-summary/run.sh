#!/bin/bash
# launchd entry point: collect, then summarize. Kept separate from the two so
# either half can be run and debugged on its own.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

if ! "$DIR/collect.sh"; then
  echo "$(date '+%F %T') [run] collect.sh failed" >> "$DIR/collect.log"
  # Overwrite the summary so the terminal shows the failure. Leaving yesterday's
  # bullets in place would read as a quiet day rather than a broken run.
  {
    printf 'collection FAILED %s\n\n' "$(date '+%F %T')"
    printf 'Could not collect from GitHub. Most likely gh could not reach the\n'
    printf 'login keychain under launchd. Check collect.log and /tmp/gh-summary.err.\n'
  } > "$DIR/summary.md"
  notify "Work summary failed" "Could not collect from GitHub. See collect.log."
  exit 1
fi
exec "$DIR/summarize.sh"
