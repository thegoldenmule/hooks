#!/usr/bin/env node
// Stop hook: blocks over-long assistant prose with "tldr".
import { appendFileSync, readFileSync } from 'node:fs';

const MAX_CHARS = Number(process.env.CLAUDE_TLDR_MAX_CHARS ?? 750);
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

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const started = Date.now();
let chars = 0;
let waited = 0;
for (;;) {
  const entries = read();
  if (entries === null) process.exit(0);
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
