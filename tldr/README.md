# tldr

A Stop hook that rejects a long closing message.

```
⎯⎯ tldr ⎯⎯ 1,712 chars of prose over a 750 limit. Asking for the short version.
```

Turns opened by a slash command whose write-up *is* the answer — `/review`,
`/code-review`, `/security-review` — are left alone, since there is nothing to
trim them down to.

### Requirements

Claude Code, and `node` on your `PATH`. No dependencies.

### Install

```sh
git clone git@github.com:thegoldenmule/hooks.git ~/projects/thegoldenmule/hooks
ln -s ~/projects/thegoldenmule/hooks/tldr/tldr.mjs ~/.claude/hooks/tldr.mjs
```

Then register it in `~/.claude/settings.json`. Add to the array rather than
replacing it, so any Stop hook you already have keeps running:

```json
{
  "hooks": {
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "node /Users/you/.claude/hooks/tldr.mjs",
            "timeout": 10
          }
        ]
      }
    ]
  }
}
```

### Configure

| Variable | Default | Purpose |
| --- | --- | --- |
| `CLAUDE_TLDR_MAX_CHARS` | `750` | Character budget for the closing message. |
| `CLAUDE_TLDR_WAIT_MS` | `2000` | How long to wait for the closing message to reach the transcript. |
| `CLAUDE_TLDR_SKIP_COMMANDS` | `review,code-review,security-review` | Slash commands to leave ungated, comma separated. `*` exempts all of them; empty gates all of them. |
| `CLAUDE_TLDR_DISABLE` | unset | Set to `1` to stand the hook down. |

### Test

```sh
./test.sh
```
