#!/usr/bin/env node
// Checks a draft against the format contract and, on failure, prints feedback
// written to be handed straight back to the model. Exit 0 pass, 1 fail.
//
// Every rule here is mechanical on purpose. "No LLM tells" is a judgement call a
// model will quietly rate itself as passing, so it is reduced to checks it
// cannot argue with. The tell vocabulary is not invented here: doc-metrics.mjs
// in the recipes repo already carries a calibrated list, and this defers to it
// so the two cannot drift. The built-in list below is the offline floor for when
// that script is not reachable.

import { readFileSync, existsSync } from "node:fs";
import { execFileSync } from "node:child_process";

const MIN_BULLETS = 3;
const MAX_BULLETS = 5;
const MAX_CHARS = 80; // counted on the text after "- "

// This is Benjamin's own log, so the subject is assumed and saying "I" is dead
// weight. Bullets open with the verb instead. VERB_FIRST is what keeps them from
// decaying into label fragments now that the pronoun check is gone.
const VERB_FIRST = true;

// Past-tense verbs that do not end in "ed", so a verb-first opening can be
// recognized without parsing. Extend this rather than loosening the rule.
const IRREGULAR_PAST = [
  "cut", "set", "left", "ran", "sent", "wrote", "rewrote", "built", "rebuilt",
  "broke", "took", "began", "split", "kept", "held", "gave", "got", "put",
  "read", "found", "made", "shut", "won", "lost", "drove", "undid", "threw",
  "hit", "let", "dealt", "meant", "spent", "told", "taught", "brought",
  "caught", "cost", "chose", "drew", "fed", "fell", "felt", "flew", "forgot",
  "froze", "grew", "hid", "knew", "laid", "led", "lent", "met", "paid", "rose",
  "said", "saw", "sold", "shot", "sat", "slept", "spoke", "stood", "stuck",
  "struck", "swept", "tore", "understood", "woke", "wore", "bent", "sped",
  "quit", "sank", "sprang", "swam", "wound", "dug", "hung", "spun", "withdrew",
];

// The shared tell vocabulary. Override the path with DOC_METRICS if the recipes
// repo moves.
const DOC_METRICS =
  process.env.DOC_METRICS ||
  `${process.env.HOME}/projects/powerhouse/recipes/.claude/tools/doc-metrics.mjs`;

// doc-metrics separates hard tells from soft ones whose plain sense is common.
// That calibration is respected, except that a 12-word factual bullet has no
// legitimate use for most of them. "harness" stays allowed because a test
// harness is a real thing in this codebase.
const SOFT_TELLS_ALLOWED = new Set(["harness"]);

// Offline floor. Deliberately overlaps doc-metrics very little: these are the
// terms it does not carry.
const BANNED_WORDS = [
  "utilize", "utilized", "utilizing", "notably", "moreover", "furthermore",
  "additionally", "comprehensive", "significant", "significantly",
  "substantial", "vital", "ultimately", "overall", "various", "numerous",
  "myriad", "plethora", "testament", "pivotal", "crucial", "underscore",
  "underscores", "showcase", "showcases", "showcasing", "spearhead",
  "spearheaded", "foster", "fostered", "empower", "empowered", "holistic",
  "synergy", "trivial", "nontrivial",
];
const BANNED_PHRASES = [
  "a number of", "several key", "wide range of", "aims to", "seeks to",
  "serves to", "helps to", "in essence", "at the end of the day",
  "best practices", "under the hood", "paves the way", "sets the stage",
  "key takeaway", "on track to", "continued to", "worked on",
];
const BANNED_PATTERNS = [
  [/\bnot only\b[^.]*\bbut\b/i, 'the "not only ... but" construction'],
  [/\bnot just\b[^.]*\bbut\b/i, 'the "not just ... but" construction'],
  [/\bisn't (just|only)\b/i, 'the "isn\'t just ..." construction'],
];

const path = process.argv[2];
if (!path) {
  console.error("usage: validate.mjs <draft-file>");
  process.exit(2);
}

// ---------------------------------------------------------------- parse
const lines = readFileSync(path, "utf8").split("\n").map((l) => l.trimEnd());
const bullets = [];
const bulletLine = []; // 1-based file line per bullet, to map doc-metrics hits
const strays = [];

lines.forEach((line, i) => {
  if (line.trim() === "") return;
  const m = line.match(/^\s*[-*•]\s+(.*)$/);
  if (m) {
    bullets.push(m[1].trim());
    bulletLine.push(i + 1);
  } else {
    strays.push(line.trim());
  }
});

// ---------------------------------------------------------------- tells
// Returns a Map of bullet index -> first tell found, or null if the shared
// vocabulary could not be consulted.
function sharedTells() {
  if (!existsSync(DOC_METRICS)) {
    process.stderr.write(
      `validate: doc-metrics.mjs not at ${DOC_METRICS}, falling back to the built-in list\n`
    );
    return null;
  }
  let report;
  try {
    report = JSON.parse(
      execFileSync(process.execPath, [DOC_METRICS, path], {
        encoding: "utf8",
        timeout: 20000,
      })
    );
  } catch (e) {
    process.stderr.write(
      `validate: doc-metrics.mjs failed (${String(e.message).split("\n")[0]}), ` +
        `falling back to the built-in list\n`
    );
    return null;
  }

  const hits = [];
  const a = report.authoritative || {};
  const c = report.candidates || {};
  for (const h of a["llm-tells"]?.hits?.items || []) {
    hits.push({ line: h.line, term: h.match, label: h.id });
  }
  for (const h of c["llm-tells-soft"]?.items || []) {
    if (!SOFT_TELLS_ALLOWED.has(h.id)) hits.push({ line: h.line, term: h.match, label: h.id });
  }
  for (const h of c["loaded-language"]?.items || []) {
    hits.push({ line: h.line, term: h.term, label: "loaded language" });
  }
  for (const h of c["brevity-hedges"]?.items || []) {
    hits.push({ line: h.line, term: h.term, label: "hedge" });
  }

  // Group every tell in a bullet into one entry. Reporting them one at a time
  // would burn a retry per synonym, since the model fixes what it is told about.
  const byBullet = new Map();
  for (const h of hits) {
    const idx = bulletLine.indexOf(h.line);
    if (idx < 0) continue;
    const list = byBullet.get(idx) || [];
    if (list.some((x) => x.term.toLowerCase() === String(h.term).toLowerCase())) continue;
    list.push(h);
    byBullet.set(idx, list);
  }
  return byBullet;
}

const tells = sharedTells();

// ---------------------------------------------------------------- checks
const problems = [];

for (const s of strays) {
  problems.push({
    where: "output",
    what: `the line "${s}" is not a bullet`,
    fix: "Output nothing but the bullet lines. No heading, no preamble, no closing remark.",
  });
}
if (bullets.length < MIN_BULLETS) {
  problems.push({
    where: "output",
    what: `only ${bullets.length} bullet${bullets.length === 1 ? "" : "s"}, the minimum is ${MIN_BULLETS}`,
    fix: `Add ${MIN_BULLETS - bullets.length} more, drawn from work in the brief you have not covered yet.`,
  });
}
if (bullets.length > MAX_BULLETS) {
  problems.push({
    where: "output",
    what: `${bullets.length} bullets, the maximum is ${MAX_BULLETS}`,
    fix: `Merge or drop ${bullets.length - MAX_BULLETS}. Keep the work that mattered most and cut the incidental.`,
  });
}

const slotsFree = Math.max(0, MAX_BULLETS - bullets.length);
const seen = new Map();

bullets.forEach((b, i) => {
  const n = i + 1;
  const at = (what, fix) => problems.push({ where: `bullet ${n}`, what, fix, text: b });
  const low = b.toLowerCase();
  const words = b.split(/\s+/).filter(Boolean);

  if (b.length > MAX_CHARS) {
    const over = b.length - MAX_CHARS;
    const splitHint =
      slotsFree > 0
        ? `, or split it into two bullets (${slotsFree} slot${slotsFree === 1 ? "" : "s"} free)`
        : " (no free bullet slots, so this one has to get shorter)";
    at(
      `${b.length} characters, ${over} over the ${MAX_CHARS} limit`,
      `Cut at least ${over} characters${splitHint}. Drop qualifiers and scene-setting before you drop facts.`
    );
  }
  if (words.length < 5) {
    at(`only ${words.length} words, too clipped to be a sentence`, "Write a full sentence with a verb and an object.");
  }
  if (!/^[A-Z"'`]/.test(b)) at("does not start with a capital letter", "Start it as a sentence.");
  if (!/[.]$/.test(b)) {
    at("does not end with a period", "End every bullet with a single period. No question or exclamation marks.");
  }
  if (/\.\.\.$/.test(b)) at("trails off in an ellipsis", "State the thing outright.");

  const saysI = /\bI\b/.test(b);
  if (saysI) {
    at('says "I", which is redundant in your own log', 'Drop the pronoun and open with the verb: "Merged ..." not "I merged ...".');
  }
  // Skip the verb check when the pronoun already explains the bad opening;
  // two complaints about one word is noise the model has to wade through.
  if (VERB_FIRST && words.length && !saysI) {
    const first = words[0].replace(/[^A-Za-z-]/g, "");
    const isPast = /ed$/i.test(first) || IRREGULAR_PAST.includes(first.toLowerCase());
    if (!isPast) {
      at(
        `opens with "${first}", which is not a past-tense verb`,
        'Lead with what you did: "Merged ...", "Cut ...", "Reverted ...", "Added ...".'
      );
    }
  }
  if (/[—–]/.test(b)) at("uses a dash as punctuation", "Split the sentence or use a comma. No em dashes or en dashes.");
  if (/;/.test(b)) at("uses a semicolon", "Use two sentences or a comma.");
  if (/\*\*|__/.test(b)) at("contains markdown emphasis", "Plain text only. These bullets are read in a terminal.");
  if (/[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}\u{FE0F}]/u.test(b)) at("contains an emoji", "Plain text only.");

  // One wording complaint per bullet: the model rewrites the whole line anyway,
  // so listing four synonyms it also used is noise. The shared vocabulary wins
  // when it has something to say.
  const shared = tells?.get(i);
  if (shared?.length) {
    const terms = shared.map((h) => `"${h.term}"`).join(", ");
    const labels = [...new Set(shared.map((h) => h.label))].join(", ");
    at(
      `uses machine-written wording: ${terms} (doc-metrics: ${labels})`,
      "Rewrite the whole bullet plainly. Name what you changed and what it now does."
    );
  } else {
    let flagged = false;
    for (const w of BANNED_WORDS) {
      if (new RegExp(`\\b${w}\\b`, "i").test(low)) {
        at(`uses the word "${w}", which reads as machine-written`, "Say plainly what happened instead.");
        flagged = true;
        break;
      }
    }
    if (!flagged) {
      for (const p of BANNED_PHRASES) {
        if (low.includes(p)) {
          at(`uses the filler phrase "${p}"`, "Replace it with the specific fact, or cut it.");
          flagged = true;
          break;
        }
      }
    }
    if (!flagged) {
      for (const [re, label] of BANNED_PATTERNS) {
        if (re.test(b)) {
          at(`uses ${label}`, "Make the claim directly in one clause.");
          break;
        }
      }
    }
  }

  const key = words.slice(0, 4).join(" ").toLowerCase();
  if (seen.has(key)) {
    at(`opens the same way as bullet ${seen.get(key)}`, "Vary the opening and make sure the two say different things.");
  } else {
    seen.set(key, n);
  }
});

// ---------------------------------------------------------------- report
const source = tells ? "doc-metrics + built-in" : "built-in only";
if (problems.length === 0) {
  const longest = bullets.length ? Math.max(...bullets.map((b) => b.length)) : 0;
  console.log(`PASS: ${bullets.length} bullets, longest ${longest}/${MAX_CHARS} chars, tells checked by ${source}.`);
  process.exit(0);
}

const out = [`FAIL: ${problems.length} problem${problems.length === 1 ? "" : "s"} to fix.`, ""];
for (const p of problems) {
  out.push(`[${p.where}] ${p.what}`);
  if (p.text) out.push(`  current: "${p.text}"`);
  out.push(`  fix: ${p.fix}`);
  out.push("");
}
out.push(
  `Rewrite the whole list. Output ${MIN_BULLETS} to ${MAX_BULLETS} bullet lines starting with "- ", ` +
    `each at most ${MAX_CHARS} characters after the marker, and nothing else.`
);
console.log(out.join("\n"));
process.exit(1);
