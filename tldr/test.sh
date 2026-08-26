#!/bin/bash
# End-to-end check: feed the hook synthetic transcripts, assert its exit code.
# 0 lets the turn end, 2 blocks it. Anything else is a crash.
set -u

HOOK="$(cd "$(dirname "$0")" && pwd)/tldr.mjs"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

node - "$WORK" <<'JS'
import { writeFileSync } from 'node:fs';
const dir = process.argv[2];
const user = (t, promptId) => ({
  type: 'user',
  ...(promptId ? { promptId } : {}),
  message: { role: 'user', content: t },
});
const result = (promptId) => ({
  type: 'user',
  ...(promptId ? { promptId } : {}),
  message: { role: 'user', content: [{ type: 'tool_result', content: 'ok' }] },
});
// How Claude Code records a typed slash command, and the prompt it expands into.
const slash = (name, promptId) => [
  user(`<command-message>${name}</command-message>\n<command-name>/${name}</command-name>\n<command-args></command-args>`, promptId),
  { type: 'user', promptId, isMeta: true, message: { role: 'user', content: [text('expanded prompt for ' + name)] } },
];
const reply = (content, isSidechain = false) => ({
  type: 'assistant',
  isSidechain,
  message: { role: 'assistant', content },
});
const text = (s) => ({ type: 'text', text: s });
const think = (s) => ({ type: 'thinking', thinking: s });
const call = () => ({ type: 'tool_use', name: 'Bash', input: {} });
const fence = '```\n' + 'y'.repeat(4000) + '\n```';

const cases = {
  short: [user('hi'), reply([text('brief')])],
  long: [user('hi'), reply([text('x'.repeat(2000))])],
  // fenced code is not prose
  code: [user('hi'), reply([text('see:\n' + fence + '\ndone')])],
  // narration before tool calls does not count, only the closer
  narration: [
    user('hi'),
    reply([text('n'.repeat(2000)), call()]),
    result(),
    reply([text('n'.repeat(900)), call()]),
    result(),
    reply([text('brief closer')]),
  ],
  // a long closer after brief narration does count
  closer: [
    user('hi'),
    reply([text('n'.repeat(200)), call()]),
    result(),
    reply([think('z'.repeat(5000)), text('L'.repeat(1000))]),
  ],
  // two text blocks in the closing message are summed
  split: [user('hi'), reply([call()]), result(), reply([text('a'.repeat(400)), text('b'.repeat(400))])],
  // a plan lives in tool_use input, so the window is empty
  plan: [
    user('hi'),
    reply([{ type: 'tool_use', name: 'ExitPlanMode', input: { plan: 'p'.repeat(10000) } }]),
  ],
  // subagent output is not addressed to the user
  subagent: [user('hi'), reply([text('x'.repeat(2000))], true), reply([text('brief')])],
  // a review's write-up is the deliverable, so it is exempt however long
  command: [
    ...slash('review', 'p1'),
    reply([call()]),
    result('p1'),
    reply([text('L'.repeat(2000))]),
  ],
  // ...and the exemption ends with that turn, not with the session
  scoped: [
    ...slash('review', 'p1'),
    reply([text('the review')]),
    user('and now a plain question', 'p2'),
    reply([text('L'.repeat(2000))]),
  ],
  // a command not on the list is gated like anything else
  unlisted: [
    ...slash('catchup', 'p1'),
    reply([text('L'.repeat(2000))]),
  ],
  // the Stop hook's own feedback shares the turn's promptId and holds no tag
  reprompt: [
    user('plain question', 'p1'),
    reply([text('L'.repeat(2000))]),
    { type: 'user', promptId: 'p1', isMeta: true, message: { role: 'user', content: 'Stop hook feedback:\n[tldr]: tldr\n' } },
    reply([text('L'.repeat(2000))]),
  ],
  // a plugin skill's name carries a namespace
  namespaced: [
    ...slash('assertion:catchup', 'p1'),
    reply([text('L'.repeat(2000))]),
  ],
  // transcripts without promptIds fall back to the nearest typed prompt
  legacy: [...slash('review'), reply([text('L'.repeat(2000))])],
  legacyPlain: [
    ...slash('review'),
    reply([text('the review')]),
    user('and now a plain question'),
    reply([text('L'.repeat(2000))]),
  ],
};

for (const [name, rows] of Object.entries(cases)) {
  writeFileSync(`${dir}/${name}.jsonl`, rows.map((r) => JSON.stringify(r)).join('\n') + '\n');
}
JS

fail=0
check() {
  local name=$1 want=$2 payload=$3
  printf '%s' "$payload" | node "$HOOK" >/dev/null 2>&1
  local got=$?
  if [ "$got" = "$want" ]; then
    printf 'ok    %-12s exit %s\n' "$name" "$got"
  else
    printf 'FAIL  %-12s exit %s, wanted %s\n' "$name" "$got" "$want"
    fail=1
  fi
}

transcript() { printf '{"stop_hook_active":false,"transcript_path":"%s/%s.jsonl"}' "$WORK" "$1"; }

echo "counting"
check short     0 "$(transcript short)"
check long      2 "$(transcript long)"
check code      0 "$(transcript code)"
check narration 0 "$(transcript narration)"
check closer    2 "$(transcript closer)"
check split     2 "$(transcript split)"
check plan      0 "$(transcript plan)"
check subagent  0 "$(transcript subagent)"

echo "slash commands"
check command     0 "$(transcript command)"
check scoped      2 "$(transcript scoped)"
check unlisted    2 "$(transcript unlisted)"
check namespaced  2 "$(transcript namespaced)"
check reprompt    2 "$(transcript reprompt)"
check legacy      0 "$(transcript legacy)"
check legacyPlain 2 "$(transcript legacyPlain)"

got=$(printf '%s' "$(transcript unlisted)" | CLAUDE_TLDR_SKIP_COMMANDS=/catchup node "$HOOK" >/dev/null 2>&1; echo $?)
[ "$got" = 0 ] \
  && echo "ok    CLAUDE_TLDR_SKIP_COMMANDS names the exempt commands" \
  || { echo "FAIL  skip list override exit $got, wanted 0"; fail=1; }
got=$(printf '%s' "$(transcript namespaced)" | CLAUDE_TLDR_SKIP_COMMANDS=assertion:catchup node "$HOOK" >/dev/null 2>&1; echo $?)
[ "$got" = 0 ] \
  && echo "ok    a namespaced plugin skill can be exempted" \
  || { echo "FAIL  namespaced override exit $got, wanted 0"; fail=1; }
got=$(printf '%s' "$(transcript command)" | CLAUDE_TLDR_SKIP_COMMANDS= node "$HOOK" >/dev/null 2>&1; echo $?)
[ "$got" = 2 ] \
  && echo "ok    an empty skip list gates every command" \
  || { echo "FAIL  empty skip list exit $got, wanted 2"; fail=1; }

# Every failure path must let the turn end rather than block it.
echo "fails open"
check reentry  0 "$(printf '{"stop_hook_active":true,"transcript_path":"%s/long.jsonl"}' "$WORK")"
check nofile   0 '{"stop_hook_active":false,"transcript_path":"/no/such/file"}'
check badinput 0 'not json'
check nostdin  0 ''

# The closing message reaches the transcript after the hook is called, so the
# hook waits for it. These two cases are that wait, from both ends.
echo "waits for the closer"
head -4 "$WORK/narration.jsonl" > "$WORK/late.jsonl"  # ends on a tool call
(sleep 0.4; node -e '
  const {appendFileSync} = require("node:fs");
  appendFileSync(process.argv[1], JSON.stringify({
    type: "assistant",
    message: {role: "assistant", content: [{type: "text", text: "L".repeat(2000)}]},
  }) + "\n");
' "$WORK/late.jsonl") &
printf '%s' "$(transcript late)" | node "$HOOK" >/dev/null 2>&1
got=$?
wait
[ "$got" = 2 ] \
  && echo "ok    blocks a closer written after the hook starts" \
  || { echo "FAIL  late closer exit $got, wanted 2"; fail=1; }

start=$(date +%s%N)
CLAUDE_TLDR_WAIT_MS=200 bash -c 'printf "%s" "$1" | node "$2" >/dev/null 2>&1' _ "$(transcript plan)" "$HOOK"
got=$?
elapsed=$(( ($(date +%s%N) - start) / 1000000 ))
if [ "$got" = 0 ] && [ "$elapsed" -lt 1500 ]; then
  echo "ok    gives up on an empty window (${elapsed}ms)"
else
  echo "FAIL  empty window exit $got after ${elapsed}ms"; fail=1
fi

echo "reports"
out=$(printf '%s' "$(transcript long)" | node "$HOOK" 2>/dev/null)
echo "$out" | grep -q 'systemMessage' \
  && echo "ok    stdout carries systemMessage" \
  || { echo "FAIL  stdout has no systemMessage"; fail=1; }
err=$(printf '%s' "$(transcript long)" | node "$HOOK" 2>&1 >/dev/null)
[ "$err" = "tldr" ] \
  && echo "ok    stderr is tldr" \
  || { echo "FAIL  stderr was '$err'"; fail=1; }

[ "$fail" = 0 ] && echo "PASS" || echo "FAILED"
exit "$fail"
