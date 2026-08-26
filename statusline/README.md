# statusline

The repo you are in and how much context is left, under the Claude Code prompt.

```
[hooks] (main)  [██████░░░░░░░░░░░░░░] 33%
```

The repo name is blue and the branch red, matching the directory and `vcs_info`
segments of my zsh prompt. The bar is green until half the context window is
gone, yellow past that, and red past three quarters.

Outside a git repo it falls back to the directory name and drops the branch. On
a detached HEAD it shows the short sha.

### Requirements

Claude Code, and `jq` on your `PATH`.

### Install

```sh
git clone git@github.com:thegoldenmule/hooks.git ~/projects/thegoldenmule/hooks
ln -s ~/projects/thegoldenmule/hooks/statusline/statusline.sh ~/.claude/statusline.sh
```

Then point `~/.claude/settings.json` at it. Unlike the hooks in this repo there
is only one status line, so this replaces whatever was there:

```json
{
  "statusLine": {
    "type": "command",
    "command": "~/.claude/statusline.sh"
  }
}
```

### Configure

Colors and the width of the bar are the constants at the top of the script.
Claude Code reports the context window as a percentage, so there is nothing to
tune about the thresholds beyond the two comparisons that pick the color.

### Test

```sh
./test.sh
```
