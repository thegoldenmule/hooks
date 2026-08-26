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

// Queries that died rather than came back empty. Everything below is a floor,
// not a count, and the prose must not turn a hole into an absence.
const failed = raw.failed_queries || [];
const missing = (...names) => names.some((n) => failed.some((f) => f.startsWith(n)));
const prsIncomplete = missing("authored_prs", "merged_prs");
const commitsIncomplete = missing("commits", "branch_commits", "pr_commits");

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
  } else if (/^Merge (branch|remote-tracking branch|pull request) /.test(subj)) {
    dropped.mergeCommits.push(entry); // a branch merge, not work of its own
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

// Commit timestamps arrive in a mix of UTC and offset form. Rendering them raw
// puts a 9pm commit on the next date, which is the same confusion that made the
// window wrong in the first place, so print them in this machine's time.
const localStamp = (iso) => {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return String(iso).slice(5, 16);
  const p2 = (n) => String(n).padStart(2, "0");
  return `${p2(d.getMonth() + 1)}-${p2(d.getDate())} ${p2(d.getHours())}:${p2(d.getMinutes())}`;
};

const prState = (p) => (p.isDraft ? "draft" : p.state || "open");
const openPrs = prs.filter((p) => !mergedNums.has(p.number) && prState(p) !== "closed");
const closedUnmerged = prs.filter((p) => !mergedNums.has(p.number) && prState(p) === "closed");

const brief = {
  window: raw.window,
  generated_at: raw.generated_at,
  truncated: raw.truncated || [],
  failed_queries: failed,
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
if (failed.length) {
  L.push(`DATA INCOMPLETE: these queries failed and returned nothing: ${failed.join(", ")}.`);
  L.push("Every count below is a floor. Describe only what is listed here, and do");
  L.push("not write that anything was absent, finished off, or left with none");
  L.push("outstanding. The collector could not see, which is not the same as empty.");
  L.push("");
}
const t = brief.totals;
const atLeast = (n, incomplete) => (incomplete ? `at least ${n}` : `${n}`);
L.push(
  `SHAPE: ${atLeast(t.commits_real, commitsIncomplete)} real commits (${t.commits_raw} raw, ${t.merge_commits_folded} merge commits folded into their PRs), ` +
    `${atLeast(t.prs_merged, prsIncomplete)} PRs merged, ${atLeast(t.prs_open, prsIncomplete)} still open, ` +
    `${atLeast(t.reviews, missing("reviewed_prs"))} reviews of others, ${atLeast(t.issues, missing("issues"))} issues.`
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
  for (const c of list) L.push(`  ${localStamp(c.date)}  ${c.subject}`);
  L.push("");
}
if (!merged.length && !kept.length && !brief.open_prs.length) {
  // Only a clean run may claim a quiet day. If a query failed, the difference
  // between "nothing happened" and "nothing was collected" is the whole point.
  L.push(failed.length ? "COLLECTION INCOMPLETE, NOTHING USABLE FOUND." : "NO ACTIVITY FOUND IN THIS WINDOW.");
}
writeFileSync(`${dir}/brief.txt`, L.join("\n") + "\n");
console.log(
  `brief: ${t.commits_real} real commits, ${t.prs_merged} merged, ${Object.keys(byRepo).length} repos` +
    (failed.length ? `, INCOMPLETE (failed: ${failed.join(", ")})` : "")
);
