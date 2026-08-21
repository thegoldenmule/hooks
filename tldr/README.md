# tldr

A Stop hook that rejects a long closing message.

When Claude finishes a turn, this counts the characters in the message it is
about to leave you with. Over the limit, the turn is blocked with a single word,
`tldr`, and Claude writes the short version instead. A divider line says what
tripped it, so you can tell a forced rewrite from a first draft.

```
⎯⎯ tldr ⎯⎯ 1,712 chars of prose over a 750 limit. Asking for the short version.
```

The long answer is not hidden. No hook can do that, because text reaches your
terminal as it is generated and the first hook to run afterward is this one. You
get the wall of text, then the divider, then the short version. That is a whip,
not a filter. If you want brevity by default, ask for it in `CLAUDE.md`, where
it shapes what gets written in the first place, and keep this for the times that
instruction gets drifted past.

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

A settings edit is not picked up mid-session. Open `/hooks` once, which reloads
the config, or restart. Edits to `tldr.mjs` itself need neither, since the file
is read on every invocation.

### Configure

| Variable | Default | Purpose |
| --- | --- | --- |
| `CLAUDE_TLDR_MAX_CHARS` | `750` | Character budget for the closing message. |
| `CLAUDE_TLDR_WAIT_MS` | `2000` | How long to wait for the closing message to reach the transcript. |
| `CLAUDE_TLDR_DISABLE` | unset | Set to `1` to stand the hook down. |

`~/.claude/tldr.log` gets one line per turn, `pass` or `block` with the count,
the limit, and how long the hook waited for the transcript. Read it for a week
before picking a number. A limit set by guesswork is either invisible or
constant.

### Test

```sh
./test.sh
```

Sixteen cases over synthetic transcripts, asserting exit codes. Two of them
cover the wait described below, including one that appends the closing message
four hundred milliseconds after the hook has already started. Run it after any
change to the counting window.

### How it works

Blocking a Stop hook means exiting with code 2 and putting the reason on
stderr. The `decision: "block"` field documented for hook output is not the
enforcement path here, and a hook that writes it and exits 0 does nothing at
all. That mistake is silent, which is why the log and the tests exist.

Claude Code passes the hook a transcript path on stdin. The hook walks that
transcript backwards from the end and counts the `text` blocks it finds, then
stops at the first tool call or user entry. That boundary is the whole design:
it means only the closing message counts.

### The message is not there yet

Reading the transcript the moment the hook is called finds everything except the
one message the hook exists to measure. Claude Code appends the closing message
a beat after Stop hooks are invoked, so the window is empty and every turn
passes at zero characters. Nothing about that looks like a bug from the outside:
the hook runs, the log fills up with `pass`, and the gate never fires.

Measured on a live session, the gap was about a hundred milliseconds:

```
17:21:13.142  hook reads the transcript   window is empty
17:21:13.240  closing message lands       window is 680 chars
```

So the hook waits. It re-reads every fifty milliseconds until the window has
something in it, up to `CLAUDE_TLDR_WAIT_MS`. The waiting is real but small,
around a tenth of a second on a normal turn.

A turn that genuinely ends without prose, on a tool call or a plan, has nothing
to wait for and pays the full timeout before giving up. Two seconds is the
default because a wrong guess in that direction costs a pause, while a wrong
guess in the other direction costs the entire feature. The `waited` figure in
the log is there to keep that number honest.

Not counted:

- Narration between tool calls. A turn that reads six files while thinking out
  loud is working, not padding. Counting the whole turn flags every
  investigation.
- Fenced code. A file you asked to see is not the hook's business.
- Plans. Plan text lives in the `input.plan` field of an `ExitPlanMode` tool
  call rather than in a text block, so it never reaches the tally. A plan is
  a structured artifact you asked for in detail, and `tldr` on one would be the
  gate misfiring.
- Thinking blocks, and anything a subagent said.

### Fail open, always

Every error path exits 0 and lets the turn end: no stdin, unparseable stdin, a
missing transcript, a half-written line at the tail of one. A gate like this
sits on every turn you take, so a bug in it must cost you nothing. The tests
assert this directly, because the failure it prevents looks exactly like
success.

One guard is not about errors. The hook input carries `stop_hook_active`, true
when the turn is already a retry, and the hook returns 0 on sight of it. Without
that, a rewrite that is also too long blocks again and the turn never lands.
Claude Code caps consecutive Stop blocks at eight as a backstop, but reaching
that cap means eight wasted rewrites.
