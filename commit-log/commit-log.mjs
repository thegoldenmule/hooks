#!/usr/bin/env node
// Stop hook: reports commits that landed since the last time it looked.
import { execFileSync } from 'node:child_process';
import {
  appendFileSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  statSync,
  unlinkSync,
  writeFileSync,
} from 'node:fs';
import { basename, dirname, isAbsolute, resolve } from 'node:path';

const MAX = Number(process.env.CLAUDE_COMMIT_LOG_MAX ?? 20);
const STATE_DIR =
  process.env.CLAUDE_COMMIT_LOG_STATE ??
  `${process.env.HOME}/.claude/state/commit-log`;
const PRUNE_DAYS = 30;

function log(msg) {
  try {
    appendFileSync(
      `${process.env.HOME}/.claude/commit-log.log`,
      `${new Date().toISOString()} ${msg}\n`,
    );
  } catch {
    // logging must never break the turn
  }
}

let raw = '';
try {
  raw = readFileSync(0, 'utf8');
} catch {
  process.exit(0);
}
if (!raw.trim() || process.env.CLAUDE_COMMIT_LOG_DISABLE === '1') process.exit(0);

let input;
try {
  input = JSON.parse(raw);
} catch {
  process.exit(0);
}

let lines;
try {
  lines = readFileSync(input.transcript_path, 'utf8').split('\n');
} catch {
  process.exit(0);
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

// The session's own start time is the floor. Without it the first run would
// report the whole history of every repo it finds.
let since = null;
for (const e of entries) {
  if (typeof e.timestamp === 'string' && !Number.isNaN(Date.parse(e.timestamp))) {
    since = e.timestamp;
    break;
  }
}
if (!since) process.exit(0);

// Directories a commit could plausibly have been made in: wherever the session
// sat, wherever a file was written, and any path handed to `cd` or `git -C`.
function pathsFromCommand(command, cwd) {
  const found = [];
  const unquote = (s) => s.replace(/^['"]|['"]$/g, '');
  const patterns = [
    /\bgit\s+-C\s+('[^']+'|"[^"]+"|[^\s;&|]+)/g,
    /(?:^|[;&|]\s*)cd\s+('[^']+'|"[^"]+"|[^\s;&|]+)/g,
  ];
  for (const re of patterns) {
    let m;
    while ((m = re.exec(command)) !== null) {
      const p = unquote(m[1]);
      if (p.startsWith('-')) continue;
      if (isAbsolute(p)) found.push(p);
      else if (cwd) found.push(resolve(cwd, p));
    }
  }
  return found;
}

const dirs = new Set();
if (typeof input.cwd === 'string') dirs.add(input.cwd);
for (const e of entries) {
  if (dirs.size > 64) break;
  const cwd = typeof e.cwd === 'string' ? e.cwd : input.cwd;
  if (typeof e.cwd === 'string') dirs.add(e.cwd);
  const blocks = e.message?.content;
  if (!Array.isArray(blocks)) continue;
  for (const b of blocks) {
    if (b?.type !== 'tool_use') continue;
    const args = b.input ?? {};
    if (typeof args.file_path === 'string' && isAbsolute(args.file_path)) {
      dirs.add(dirname(args.file_path));
    }
    if (typeof args.command === 'string') {
      for (const p of pathsFromCommand(args.command, cwd)) dirs.add(p);
    }
  }
}

function git(cwd, args) {
  try {
    return execFileSync('git', args, {
      cwd,
      encoding: 'utf8',
      timeout: 5000,
      stdio: ['ignore', 'pipe', 'ignore'],
    }).trim();
  } catch {
    return null;
  }
}

// Many directories collapse to a handful of repositories.
const repos = new Set();
for (const dir of dirs) {
  const top = git(dir, ['rev-parse', '--show-toplevel']);
  if (top) repos.add(top);
}
if (repos.size === 0) process.exit(0);

const stateFile = `${STATE_DIR}/${String(input.session_id ?? 'unknown').replace(/[^\w.-]/g, '_')}.json`;
let state = { seen: {} };
try {
  state = JSON.parse(readFileSync(stateFile, 'utf8'));
  if (!state || typeof state.seen !== 'object' || state.seen === null) state = { seen: {} };
} catch {
  // first turn of the session, or a state file we can no longer read
}

const fresh = [];
for (const repo of [...repos].sort()) {
  const out = git(repo, [
    'log',
    `--since=${since}`,
    `--max-count=${MAX + 50}`,
    '--format=%H%x00%h%x00%s',
    'HEAD',
  ]);
  if (!out) continue;
  const seen = new Set(state.seen[repo] ?? []);
  // git log is newest first; report in the order the commits were made.
  const rows = out.split('\n').filter(Boolean).reverse();
  for (const row of rows) {
    const [sha, short, subject] = row.split('\0');
    if (!sha || seen.has(sha)) continue;
    seen.add(sha);
    fresh.push({ repo: basename(repo), short, subject: subject ?? '' });
  }
  state.seen[repo] = [...seen];
}

try {
  mkdirSync(STATE_DIR, { recursive: true });
  writeFileSync(stateFile, JSON.stringify(state));
  const cutoff = Date.now() - PRUNE_DAYS * 86400000;
  for (const name of readdirSync(STATE_DIR)) {
    const f = `${STATE_DIR}/${name}`;
    if (statSync(f).mtimeMs < cutoff) unlinkSync(f);
  }
} catch {
  // an unwritable state file means repeats, not a broken turn
}

if (fresh.length === 0) process.exit(0);

const shown = fresh.slice(-MAX);
const names = new Set(shown.map((c) => c.repo));
const multi = names.size > 1;
const pad = multi ? Math.max(...shown.map((c) => c.repo.length)) : 0;

const head =
  `⎯⎯ commits ⎯⎯ ${fresh.length} new` +
  (multi ? '' : ` in ${shown[0].repo}`) +
  (fresh.length > shown.length ? `, last ${shown.length} shown` : '');
const body = shown.map(
  (c) => `  ${multi ? `${c.repo.padEnd(pad)}  ` : ''}${c.short}  ${c.subject}`,
);

console.log(JSON.stringify({ systemMessage: [head, ...body].join('\n') }));
log(`report ${fresh.length} across ${repos.size} repo(s)`);
process.exit(0);
