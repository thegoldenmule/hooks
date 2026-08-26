# hooks

Personal automation, mostly hooks. One folder per piece, each with its own
README and its own install steps. Nothing here is shared between them, so any
one of them can be installed or removed on its own.

| | What it does |
| --- | --- |
| [work-summary](work-summary) | Asks GitHub what you did yesterday and writes it up as three to five bullets, checked against a format contract before you see it. Runs weekday mornings under launchd and prints in your next terminal. |
| [commit-log](commit-log) | Prints the commits that landed since it last looked, at the end of a Claude Code turn. Silent when nothing was committed, and each commit is reported once. |
| [tldr](tldr) | Counts the closing message of a Claude Code turn and blocks it with one word when it runs long, so the next thing you read is the short version. |
| [statusline](statusline) | Not a hook. The repo and branch you are in, and a bar for how much of the context window is gone, under the Claude Code prompt. |

Requirements vary. Everything so far assumes macOS.
