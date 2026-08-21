#!/usr/bin/env node
// latest.json -> brief.json + brief.txt
//
// The raw gh output is not safe to summarize directly. It counts every merge
// commit twice (once as the commit, once as the PR), lists a revert next to the
// commit it undid as though both were accomplishments, and flattens unrelated
// repos into one stream. This collapses all three before a model sees it.

import { readFileSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const dir = process.env.GH_SUMMARY_DIR || process.env.DIR || here;
const raw = JSON.parse(readFileSync(`${dir}/latest.json`, "utf8"));

if (raw.error) {
  writeFileSync(`${dir}/brief.txt`, `COLLECTION FAILED: ${raw.error}\n`);
  writeFileSync(`${dir}/brief.json`, JSON.stringify({ error: raw.error }, null, 2));
  console.error(`collection failed: ${raw.error}`);
  process.exit(2);
}

// PRs report repository.nameWithOwner; commit search reports repository.fullName.
const repoOf = (x) => x?.repository?.nameWithOwner || x?.repository?.fullName || "unknown";
const subject = (m) => String(m || "").split("\n")[0].trim();

const prs = raw.authored_prs || [];
const merged = raw.merged_prs || [];
const commits = raw.commits || [];
const mergedNums = new Set(merged.map((p) => p.number));
const knownNums = new Set([...prs, ...merged].map((p) => p.number));

// Pass 1: find what was reverted, so neither the work nor its revert is
// reported as a win.
const revertedTitles = new Set();
for (const c of commits) {
  const m = subject(c.commit?.message).match(/^Revert "(.+)"$/);
  if (m) revertedTitles.add(m[1].trim());
}

// Pass 2: classify every commit.
const kept = [];
const dropped = { mergeCommits: [], reverts: [], revertedWork: [] };
for (const c of commits) {
  const subj = subject(c.commit?.message);
  const entry = {
    sha: (c.sha || "").slice(0, 8),
    repo: repoOf(c),
    subject: subj,
    date: c.commit?.author?.date || "",
  };
  const prRef = subj.match(/\(#(\d+)\)$/);
  if (prRef && knownNums.has(Number(prRef[1]))) {
    dropped.mergeCommits.push(entry); // the PR entry already covers this
  } else if (/^Revert "/.test(subj)) {
    dropped.reverts.push(entry);
  } else if (revertedTitles.has(subj)) {
    dropped.revertedWork.push(entry);
  } else {
    kept.push(entry);
  }
}

// Group the surviving commits by repo, newest last.
const byRepo = {};
for (const c of kept) (byRepo[c.repo] ||= []).push(c);
for (const list of Object.values(byRepo)) list.sort((a, b) => a.date.localeCompare(b.date));

// Exact per-type counts. A model asked to summarize 24 rows will miscount them,
// so the arithmetic happens here and the prose just quotes it.
const tally = (list) => {
  const t = {};
  for (const c of list) {
    const m = c.subject.match(/^([a-z]+)(\([^)]*\))?!?:/);
    const kind = m ? m[1] : "other";
    t[kind] = (t[kind] || 0) + 1;
  }
  return Object.entries(t).sort((a, b) => b[1] - a[1]);
};

const prState = (p) => (p.isDraft ? "draft" : p.state || "open");
const openPrs = prs.filter((p) => !mergedNums.has(p.number) && prState(p) !== "closed");
const closedUnmerged = prs.filter((p) => !mergedNums.has(p.number) && prState(p) === "closed");

const brief = {
  window: raw.window,
  generated_at: raw.generated_at,
  truncated: raw.truncated || [],
  totals: {
    commits_raw: commits.length,
    commits_real: kept.length,
    merge_commits_folded: dropped.mergeCommits.length,
    reverted_pairs: dropped.reverts.length,
    prs_merged: merged.length,
    prs_open: openPrs.length,
    prs_closed_unmerged: closedUnmerged.length,
    reviews: (raw.reviewed_prs || []).length,
    issues: (raw.issues || []).length,
  },
  merged_prs: merged.map((p) => ({ repo: repoOf(p), number: p.number, title: p.title })),
  open_prs: openPrs.map((p) => ({ repo: repoOf(p), number: p.number, title: p.title, state: prState(p) })),
  closed_unmerged_prs: closedUnmerged.map((p) => ({ repo: repoOf(p), number: p.number, title: p.title })),
  reverted: [...revertedTitles],
  commits_by_repo: byRepo,
  commit_kinds_by_repo: Object.fromEntries(
    Object.entries(byRepo).map(([r, l]) => [r, Object.fromEntries(tally(l))])
  ),
};
writeFileSync(`${dir}/brief.json`, JSON.stringify(brief, null, 2));

// The text rendering is what the model actually reads.
const L = [];
L.push(`WINDOW: ${brief.window}`);
L.push("");
if (brief.truncated.length) {
  L.push(`WARNING: these queries hit the result cap and may be incomplete: ${brief.truncated.join(", ")}`);
  L.push("");
}
const t = brief.totals;
L.push(
  `SHAPE: ${t.commits_real} real commits (${t.commits_raw} raw, ${t.merge_commits_folded} merge commits folded into their PRs), ` +
    `${t.prs_merged} PRs merged, ${t.prs_open} still open, ${t.reviews} reviews of others, ${t.issues} issues.`
);
L.push("");

if (merged.length) {
  L.push("MERGED (landed, safe to claim):");
  for (const p of brief.merged_prs) L.push(`  ${p.repo}#${p.number}  ${p.title}`);
  L.push("");
}
if (brief.open_prs.length) {
  L.push("STILL OPEN (in flight, do not call finished):");
  for (const p of brief.open_prs) L.push(`  ${p.repo}#${p.number} [${p.state}]  ${p.title}`);
  L.push("");
}
if (brief.closed_unmerged_prs.length) {
  L.push("CLOSED WITHOUT MERGING (abandoned, not an accomplishment):");
  for (const p of brief.closed_unmerged_prs) L.push(`  ${p.repo}#${p.number}  ${p.title}`);
  L.push("");
}
if (brief.reverted.length) {
  L.push("REVERTED (went in and came back out; report as backed out, never as done):");
  for (const r of brief.reverted) L.push(`  ${r}`);
  L.push("");
}
for (const [repo, list] of Object.entries(byRepo)) {
  const counts = tally(list).map(([k, n]) => `${n} ${k}`).join(", ");
  L.push(`COMMITS IN ${repo} (${list.length}: ${counts}):`);
  for (const c of list) L.push(`  ${c.date.slice(5, 16)}  ${c.subject}`);
  L.push("");
}
if (!merged.length && !kept.length && !brief.open_prs.length) {
  L.push("NO ACTIVITY FOUND IN THIS WINDOW.");
}
writeFileSync(`${dir}/brief.txt`, L.join("\n") + "\n");
console.log(`brief: ${t.commits_real} real commits, ${t.prs_merged} merged, ${Object.keys(byRepo).length} repos`);
