# work-summary

A weekday work-log summarizer.

Every weekday at 5:00 AM, launchd asks GitHub what you did the previous day, has
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

# schedule it: weekdays at 5:00 AM
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

`collect.sh` queries GitHub and writes `latest.json`. Monday reaches back three
days so Friday is covered. Three things about that window and its coverage are
easy to get wrong, and getting them wrong reads as a quiet day rather than as a
bug:

- **The window carries an offset.** GitHub's date qualifiers are UTC unless the
  value says otherwise, but "yesterday" has to mean yesterday here. A bare
  `--updated=2026-08-25..2026-08-25` drops everything after 7pm CDT into the
  next UTC day, so an evening of work vanishes. The window is built as
  `2026-08-25T00:00:00-05:00..2026-08-25T23:59:59-05:00`, with the offset read
  from the target days themselves so a DST boundary inside the window holds.
- **PRs are matched on `created` as well as `updated`.** `updated` is a single
  last-touched timestamp, so it surfaces a PR only on the day it was last
  touched. A PR opened and worked all day appears once, at the end, and is
  invisible on every day between. The two result sets are unioned on `url`.
- **PR commits are read per PR, not from commit search.** `gh search commits`
  only indexes default branches, so a day spent entirely on a feature branch
  reports zero commits and leaves the summary nothing to describe but the merge.
  Every PR found above is walked with `gh pr view --json commits`, filtered to
  your own authorship inside the window, and merged with the search results,
  deduplicated on sha. `PR_CAP` bounds the API calls.

A query that fails is not a query that returned nothing. `q()` retries three
times with backoff, and a query that stays dead is named in `failed_queries` in
`latest.json` rather than becoming an empty array. `brief.mjs` then prints a
`DATA INCOMPLETE` banner, reports the affected counts as `at least N`, and
refuses to emit `NO ACTIVITY FOUND`, because the difference between "nothing
happened" and "nothing was collected" is the one thing the summary must not
blur.

`brief.mjs` shapes that into `brief.txt`. The raw output is not safe to
summarize directly: it counts every merge commit twice, once as the commit and
once as the PR, it lists a revert beside the commit it undid as though both were
wins, and it flattens unrelated repositories into one stream. This folds,
labels, and groups all three, and tallies commits per type so the model never
counts rows itself.

`summarize.sh` calls `claude -p`, then `validate.mjs`. A rejected draft goes
back with the validator's complaints attached, up to four attempts.

Two different things fail there and the run says which. A draft that never
passes the format check keeps the validator's last report. A `claude` that never
returns a draft is a separate failure, and `summary.md` shows the error it
printed, because calling that one a format failure sent a morning looking for a
bad draft that had never been written. An error naming authentication stops the
retries early: an expired login fails the same way four times and only delays
the one message worth reading.

The bullets are only ever the ones this run produced. `draft.md` is removed
before the first attempt, because reading a stale one republished the previous
day's bullets under today's date, in `history.md` as well as `summary.md`. A run
that produces no bullets leaves `history.md` untouched rather than replacing a
good section with an empty one, and a draft that failed the format check is
recorded there with a line saying so.

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

A run that lost only some of its queries still writes bullets, since partial
data is better than none, but `summary.md` gains an `INCOMPLETE:` line naming
what failed and the terminal says the day may be under-reported. A run that lost
queries and found nothing usable writes no bullets at all and says so. Neither
case is ever phrased as an absence: `prompt.md` forbids claiming that nothing
was left open or that the day closed clean, because an empty list is as likely
to be a dead query as a thing that did not happen.

Notification Center is not used. An `osascript` notification is attributed to
Script Editor, and if that is suppressed in System Settings the banner is
dropped while `osascript` still exits 0, which fails invisibly. `env.sh` still
has a best-effort `notify`, but nothing depends on it.
