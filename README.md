# hooks

Personal automation hooks. One folder per hook, each with its own README and its
own install steps. Nothing here is shared between them, so a hook can be
installed or removed on its own.

| Hook | What it does |
| --- | --- |
| [work-summary](work-summary) | Asks GitHub what you did yesterday and writes it up as three to five bullets, checked against a format contract before you see it. Runs weekday mornings under launchd and prints in your next terminal. |
| [tldr](tldr) | Counts the closing message of a Claude Code turn and blocks it with one word when it runs long, so the next thing you read is the short version. |

Requirements vary by hook. Everything so far assumes macOS.
