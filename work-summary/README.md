# work-summary

A weekday work-log summarizer.

Every weekday at 7:55 AM, launchd asks GitHub what you did the previous day, has
Claude write it up as three to five bullets, and rejects that draft until it
meets a format contract. The bullets appear in the next terminal you open.

```
Work log 2026-08-20..2026-08-20
  - Merged the auth policy check into sync serving.
  - Added a typed execute call and moved every caller onto it.
  - Cut the license and regeneration sections from twenty-one READMEs.
  - Reverted the action typing after it broke two producers.
```

### Requirements

macOS, plus `gh` (authenticated), `node`, and the `claude` CLI. Querying happens
locally because a sandbox cannot reach the GitHub API with your credentials.

### Install

```sh
git clone git@github.com:thegoldenmule/hooks.git ~/projects/thegoldenmule/hooks
cd ~/projects/thegoldenmule/hooks/work-summary

# schedule it: weekdays at 7:55 AM
cp com.thegoldenmule.hooks.work-summary.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.thegoldenmule.hooks.work-summary.plist
```

The plist runs `run.sh` from `~/projects/thegoldenmule/hooks/work-summary`. If
you cloned somewhere else, edit that one path before copying it.

Then have your shell print the bullets. In `.zshrc`:

```sh
if [[ -o interactive ]] && [[ -x "$HOME/projects/thegoldenmule/hooks/work-summary/show.sh" ]]; then
  "$HOME/projects/thegoldenmule/hooks/work-summary/show.sh"
fi
worklog() { "$HOME/projects/thegoldenmule/hooks/work-summary/show.sh" --force; }
```

Use `add-zsh-hook` if you want this on a prompt hook instead of at startup.
Redefining `precmd` will clobber whatever else already uses it.

### Run it

```sh
./run.sh          # collect and summarize, exactly what launchd does
./summarize.sh    # re-summarize without re-querying GitHub
./show.sh --force # reprint, same as the worklog function
cat summary.md    # today's bullets
cat history.md    # one dated section per day
```

`launchctl kickstart gui/$(id -u)/com.thegoldenmule.hooks.work-summary` forces a scheduled
run. `launchctl list | grep work-summary` says whether it is loaded.

### Configure

| Variable | Default | Purpose |
| --- | --- | --- |
| `GH_SUMMARY_ORG` | `powerhouse-inc` | Which org to search. |
| `GH_SUMMARY_DIR` | the script directory | Where the data files are written. |
| `DOC_METRICS` | a path in the recipes repo | The shared LLM-tell vocabulary. |

### How it works

`run.sh` calls `collect.sh`, then `summarize.sh`.

`collect.sh` runs five `gh search` queries and writes `latest.json`. Monday
reaches back three days so Friday is covered.

`brief.mjs` shapes that into `brief.txt`. The raw output is not safe to
summarize directly: it counts every merge commit twice, once as the commit and
once as the PR, it lists a revert beside the commit it undid as though both were
wins, and it flattens unrelated repositories into one stream. This folds,
labels, and groups all three, and tallies commits per type so the model never
counts rows itself.

`summarize.sh` calls `claude -p`, then `validate.mjs`. A rejected draft goes
back with the validator's complaints attached, up to four attempts.

`validate.mjs` is the authority on format, not the prompt. It enforces:

- Three to five bullets and nothing else in the output.
- Eighty characters maximum per bullet, counted after the `- `.
- A past-tense verb to open, and no `I`. The log is yours, so the subject is
  assumed. `VERB_FIRST` and `IRREGULAR_PAST` are what stop that from decaying
  into label fragments. Add to `IRREGULAR_PAST` rather than loosening the rule.
- No em dashes, en dashes, semicolons, markdown emphasis, or emoji.
- No machine-written wording. That vocabulary comes from `doc-metrics.mjs` in
  another repo rather than a second list that would drift from it. If it cannot
  be reached, a smaller built-in list runs and the PASS line says so instead of
  implying the full check happened.

It consumes that script's hard `llm-tells` plus its `loaded-language` and
`brevity-hedges` candidates, and ignores its document-shape and
sentence-mechanics scoring, which is calibrated for prose documents rather than
five bullets.

Two deliberate divergences from it. `doc-metrics.mjs` reports loaded language and
hedges as candidates for a model to adjudicate, because in a long document
"simple" might be accurate; in a twelve-word factual bullet it never is, so they
fail here. Its soft tells fail too, except `harness`, since a test harness is a
real thing. `SOFT_TELLS_ALLOWED` is where that lives.

To change a rule, edit the constants at the top of `validate.mjs` and the
matching line in `prompt.md`. Keep the two in step: the prompt is what makes the
first attempt pass, the validator is what makes the rule real.

### When a morning is empty

`gh` keeps its token in the login keychain, the likeliest thing to fail under
launchd's bare environment. `collect.sh` checks `gh auth status` first and a
failed run overwrites `summary.md` with the reason, so a broken morning shows up
in the terminal instead of looking like a quiet day. Check `collect.log`, then
`/tmp/work-summary.err`.

Notification Center is not used. An `osascript` notification is attributed to
Script Editor, and if that is suppressed in System Settings the banner is
dropped while `osascript` still exits 0, which fails invisibly. `env.sh` still
has a best-effort `notify`, but nothing depends on it.
