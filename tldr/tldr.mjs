#!/usr/bin/env node
// Stop hook: blocks over-long assistant prose with "tldr".
import { appendFileSync, readFileSync } from 'node:fs';

const MAX_CHARS = Number(process.env.CLAUDE_TLDR_MAX_CHARS ?? 750);
// Some slash commands answer in the closing message: the write-up *is* the
// deliverable, so trimming it is a loss, not a mercy. `*` exempts every command.
const SKIP_COMMANDS = (
  process.env.CLAUDE_TLDR_SKIP_COMMANDS ?? 'review,code-review,security-review'
)
  .split(',')
  .map((c) => c.trim().replace(/^\//, ''))
  .filter(Boolean);
// The closing message reaches the transcript after this hook is called, so an
// empty window means "not written yet" far more often than it means "no prose".
const WAIT_MS = Number(process.env.CLAUDE_TLDR_WAIT_MS ?? 2000);
const POLL_MS = 50;

let raw = '';
try {
  raw = readFileSync(0, 'utf8');
} catch {
  process.exit(0);
}
if (!raw.trim() || process.env.CLAUDE_TLDR_DISABLE === '1') process.exit(0);

let input;
try {
  input = JSON.parse(raw);
} catch {
  process.exit(0);
}

// Second pass through the hook: let the turn end or it ping-pongs.
if (input.stop_hook_active) process.exit(0);

function read() {
  let lines;
  try {
    lines = readFileSync(input.transcript_path, 'utf8').split('\n');
  } catch {
    return null;
  }
  const entries = [];
  for (const line of lines) {
    if (!line.trim()) continue;
    try {
      entries.push(JSON.parse(line));
    } catch {
      // partial write at the tail
    }
  }
  return entries;
}

// Fenced code isn't prose; a long file dump shouldn't trip the gate.
function prose(text) {
  return text.replace(/```[\s\S]*?(```|$)/g, '');
}

function log(msg) {
  try {
    appendFileSync(
      `${process.env.HOME}/.claude/tldr.log`,
      `${new Date().toISOString()} ${msg}\n`,
    );
  } catch {
    // logging must never break the gate
  }
}

// Only the closing message counts. Walking back from the end, a tool call or
// any user entry ends the window, so narration between tools is not tallied.
function count(entries) {
  let chars = 0;
  for (let i = entries.length - 1; i >= 0; i--) {
    const e = entries[i];
    if (e.type === 'user') break;
    if (e.type !== 'assistant' || e.isSidechain) continue;
    const blocks = e.message?.content ?? [];
    if (blocks.some((b) => b.type === 'tool_use')) break;
    for (const b of blocks) {
      if (b.type === 'text') chars += prose(b.text ?? '').length;
    }
  }
  return chars;
}

// `:` so that a plugin skill (`assertion:catchup`) can be named in the list too.
const TAG = /<command-name>\s*\/?([\w:-]+)\s*<\/command-name>/;

// The slash command that opened this turn, if any. Every entry of a turn shares
// a promptId, so that scopes the search; the typed command survives in the
// transcript as a `<command-name>` tag on a string-content user entry, while the
// expanded prompt it becomes does not carry the tag.
function command(entries) {
  const users = entries.filter((e) => e.type === 'user' && !e.isSidechain);
  if (!users.length) return null;
  // Taking it from the *last* user entry is what keeps the scope on this turn:
  // an unlabelled turn gets `undefined`, which no labelled entry can match.
  const promptId = users[users.length - 1].promptId;
  for (let i = users.length - 1; i >= 0; i--) {
    const e = users[i];
    if (e.promptId !== promptId) break;
    const content = e.message?.content;
    // Tool results and the expanded prompt arrive as blocks and carry no tag;
    // only the typed line is a string, so only it can end the search.
    if (typeof content !== 'string') continue;
    const found = content.match(TAG);
    if (found) return found[1];
    // Older transcripts have no promptIds at all, so the nearest typed prompt
    // is the boundary: reaching a plain one means this turn began plainly.
    if (promptId === undefined) break;
  }
  return null;
}

function exempt(entries) {
  try {
    const name = command(entries);
    if (!name) return null;
    return SKIP_COMMANDS.includes('*') || SKIP_COMMANDS.includes(name)
      ? name
      : null;
  } catch {
    // A detection slip must not exempt a turn, and must not block one either.
    return null;
  }
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const started = Date.now();
let chars = 0;
let waited = 0;
for (;;) {
  const entries = read();
  if (entries === null) process.exit(0);
  const skipped = exempt(entries);
  if (skipped) {
    log(`skip /${skipped}`);
    process.exit(0);
  }
  chars = count(entries);
  waited = Date.now() - started;
  if (chars > 0 || waited >= WAIT_MS) break;
  await sleep(POLL_MS);
}

if (chars <= MAX_CHARS) {
  log(`pass ${chars}/${MAX_CHARS} waited ${waited}ms`);
  process.exit(0);
}

const shown = chars.toLocaleString('en-US');
const cap = MAX_CHARS.toLocaleString('en-US');
const line = `\u23af\u23af tldr \u23af\u23af ${shown} chars of prose over a ${cap} limit. Asking for the short version.`;

// stdout JSON carries the user-visible message
console.log(
  JSON.stringify({ systemMessage: line, rewakeSummary: 'tldr' }),
);
// exit 2 + stderr is what actually blocks the turn
process.stderr.write('tldr\n');
log(`block ${chars}/${MAX_CHARS} waited ${waited}ms`);
process.exit(2);
