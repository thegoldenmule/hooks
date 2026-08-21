# commit-log

A Stop hook that tells you what got committed.

At the end of a turn it looks for commits that landed since it last looked, and
prints them under a divider. Nothing new, nothing printed, so most turns are
silent. Each commit is reported once.

```
⎯⎯ commits ⎯⎯ 3 new
  hooks        75cedbd  Add commit-log hook
  hooks        64d3584  Fix baseline lookup
  hotseat-web  535ef8a  Bump deps
```

When every commit came from the same repository the header says so
(`3 new in hooks`) and the column is dropped.

This is a receipt, not a gate. It never blocks a turn and it never fails a
turn: every error path exits quietly and leaves the session alone.

### Requirements

Claude Code, plus `node` and `git` on your `PATH`. No dependencies.

### Install

```sh
git clone git@github.com:thegoldenmule/hooks.git ~/projects/thegoldenmule/hooks
ln -s ~/projects/thegoldenmule/hooks/commit-log/commit-log.mjs ~/.claude/hooks/commit-log.mjs
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
            "command": "node /Users/you/.claude/hooks/commit-log.mjs",
            "timeout": 10
          }
        ]
      }
    ]
  }
}
```

A settings edit is not picked up mid-session. Open `/hooks` once, which reloads
the config, or restart. Edits to `commit-log.mjs` itself need neither, since the
file is read on every invocation.

### Configure

| Variable | Default | Purpose |
| --- | --- | --- |
| `CLAUDE_COMMIT_LOG_MAX` | `20` | Most commits listed at once. Older ones are counted in the header, not printed. |
| `CLAUDE_COMMIT_LOG_STATE` | `~/.claude/state/commit-log` | Where the per-session record of reported commits lives. |
| `CLAUDE_COMMIT_LOG_DISABLE` | unset | Set to `1` to stand the hook down. |

State files are keyed by session id and swept after thirty days.
`~/.claude/commit-log.log` gets a line each time the hook reports something.

### Test

```sh
./test.sh
```

Eighteen cases against real throwaway repositories: reporting, the once-only
rule, repository discovery, and every path that has to stay quiet.

### How it works

Claude Code hands a Stop hook a transcript path, a session id, and a working
directory on stdin. Two questions follow from that: which repositories to look
at, and how far back to look.

Repositories come from the transcript. The hook collects the session's working
directory, the `cwd` on every entry, the directory of every file written, and
any path handed to `cd` or `git -C` in a Bash call. Each one is resolved with
`git rev-parse --show-toplevel` and the results are deduplicated, so a handful
of directories usually collapses to one or two repositories. A commit made in a
sibling repository you only ever touched through `git -C` still shows up.

How far back is the timestamp on the first transcript entry, which is when the
session began. Everything older is somebody else's history.

That window alone would reprint the same commits every turn, so the hook keeps
a per-session file of the SHAs it has already reported and subtracts them. The
window and the record do different jobs: the window is what makes the first
turn of a session sane, the record is what makes every turn after it quiet.

### What it will and won't catch

It reports commits, not authorship. A commit you make yourself in another
terminal during the session is still a commit that landed in the window, and it
will be listed. There is no signal in a repository that says who drove the
commit, so the hook does not pretend to know.

Rewriting history re-reports. An amend or a rebase produces new SHAs, and new
SHAs are new commits as far as the record is concerned. This is arguably right:
the old commit is gone and the new one is what you have.

Only `HEAD` is walked. Commit on a branch, switch away, and those commits leave
the history the hook can see. They are not lost, just not printed.
