#!/usr/bin/env node
// Reports prose that breaks the ASD-STE100 writing rules a script can see.
//
//   node tools/check-ste.mjs [--verbose] [--strict] <file or directory>...
//
// Reads .mdx chapters (prose outside code, plus frontmatter description,
// seoDescription and Playground note props) and .zig snippets (comments).
// It is a heuristic. A word it flags can be a correct technical name: add
// that word to TECHNICAL rather than rewording a correct sentence.
//
// Exits 0 unless --strict is given, so it can report before the guide passes.

import { readFileSync, readdirSync, statSync } from "node:fs";
import { join, relative } from "node:path";

const MAX_WORDS = 25; // descriptive limit; an instruction should stay under 20
const MAX_SENTENCES = 6;

// Words that end in -ing but are nouns, technical names or STE-approved words.
const TECHNICAL = new Set(
  `string strings thing things nothing something anything everything during
   padding ownership king ring spring morning evening ceiling bring brings
   ping pings building buildings binding bindings mapping mappings encoding
   encodings heading headings setting settings warning warnings ending endings
   timing offering spacing rounding casing listing listings rendering
   threading logging hashing parsing ordering tiling wiring sibling siblings
   underlying swing sing wing wings sting kerning blending smoothing antialiasing
   shading clipping dithering scaling caching pooling plumbing routing
   tokenizing linking polling streaming batching padding painting drawing
   drawings meaning meanings beginning greeting backing formatting testing
   addressing probing chaining clustering splicing bookkeeping coupling
   ascending descending operating
   sorting falling rising running
   blocking networking interleaving publishing outstanding dangling aliasing
   programming framing self-describing reordering sliding
   working coloring spanning folding saving substring combining allocating
   signalling saturating learning calling narrowing wrapping mixing
   closing nesting packing counting pipelining handling spelling sharing
   profiling moving boxing debugging balancing meeting trailing ranking
   compositing interlacing bounding buffering winding culling supersampling
   ringing opening resampling sampling hinting blitting
   tree-walking walking lexing backpatching hoisting lowering shaping freestanding pending mangling marshalling
   escaping smuggling listening decoding shadowing recording sourcing branching
   journalling quoting climbing planning spawning
   thrashing scripting positioning stacking`.split(/\s+/).filter(Boolean),
);

// Words after "is" that end like a participle but are not one.
const NOT_PARTICIPLE = new Set(
  "open often even then when token seven eleven heaven garden kitchen between children fourteen thirteen".split(" "),
);

const PHRASAL = [
  "go back", "goes back", "went back", "come back", "comes back",
  "find out", "finds out", "figure out", "figures out",
  "set up", "sets up", "look up", "looks up", "end up", "ends up",
  "carry out", "carries out", "point out", "points out", "turn out", "turns out",
  "turn into", "turns into", "show up", "shows up", "pick up", "picks up",
  "fill in", "fills in", "get rid of", "keep track of", "keeps track of",
  "take care of", "takes care of", "give up", "gives up", "hand off", "hands off",
  "deal with", "deals with", "run into", "runs into", "work out", "works out",
];
const PHRASAL_RE = new RegExp(`\\b(${PHRASAL.join("|")})\\b`, "i");

const RULES = [
  ["we", /\b(we|us|our|ours|ourselves|let's)\b/i],
  ["contraction", /\b\w+(n't|'re|'ll|'ve|'d)\b|\b(it|that|there|here|what|who)'s\b/i],
  ["perfect", /\b(has|have|had)\s+(been|\w+ed|\w+en|done|made|gone|found|read|written|run|got)\b/i, (m) => !NOT_PARTICIPLE.has(m[2].toLowerCase())],
  ["progressive", /\b(am|is|are|was|were|be|been)\s+(\w{2,}ing)\b/i, (m) => !TECHNICAL.has(m[2].toLowerCase())],
  ["passive?", /\b(is|are|was|were|be|been|being)\s+(\w+ed|\w+en|done|made|found|read|written|run|kept|held|built|sent|set)\b/i, (m) => !NOT_PARTICIPLE.has(m[2].toLowerCase())],
  ["phrasal", PHRASAL_RE],
  ["dash", /[—–]/],
];

function ingWords(s) {
  const out = [];
  for (const m of s.matchAll(/\b([A-Za-z]{3,}ing)\b/g)) {
    if (!TECHNICAL.has(m[1].toLowerCase())) out.push(m[1]);
  }
  return out;
}

// Replace everything that is not prose with blanks, keeping line numbers.
function blank(s) {
  return s.replace(/[^\n]/g, " ");
}

function proseOfMdx(text) {
  const units = []; // { line, text, kind }
  let body = text;
  const fm = text.match(/^---\n([\s\S]*?)\n---\n/);
  if (fm) {
    fm[1].split("\n").forEach((l, i) => {
      const m = l.match(/^(description|seoDescription):\s*(.*)$/);
      if (m) units.push({ line: i + 2, text: m[2].replace(/^["']|["']$/g, ""), kind: "para" });
    });
    body = blank(fm[0]) + text.slice(fm[0].length);
  }
  body = body.replace(/```[\s\S]*?```/g, blank);
  body = body.replace(/<!--[\s\S]*?-->/g, blank);
  // JSX elements: keep note="..." text, blank the rest.
  body = body.replace(/<[A-Za-z/][^>]*>/g, (tag, offset) => {
    const note = tag.match(/\bnote="([^"]*)"/);
    if (note) {
      const line = body.slice(0, offset).split("\n").length;
      units.push({ line, text: note[1], kind: "para" });
    }
    return blank(tag);
  });
  body = body.replace(/^(import|export)\b.*$/gm, blank);
  body = body.replace(/^\s*\|.*$/gm, blank); // tables
  body = body.replace(/`[^`\n]*`/g, "CODE");
  body = body.replace(/!?\[([^\]]*)\]\([^)]*\)/g, "$1");
  body = body.replace(/\*\*|__|(?<!\w)[*_](?!\s)|(?<!\s)[*_](?!\w)/g, "");

  const lines = body.split("\n");
  let para = null;
  const flush = () => {
    if (para && para.text.trim()) units.push(para);
    para = null;
  };
  lines.forEach((l, i) => {
    const t = l.trim();
    if (!t) return flush();
    if (/^#{1,6}\s/.test(t)) {
      flush();
      units.push({ line: i + 1, text: t.replace(/^#+\s*/, ""), kind: "heading" });
      return;
    }
    if (/^([-*+]|\d+\.)\s/.test(t)) {
      flush();
      para = { line: i + 1, text: t.replace(/^([-*+]|\d+\.)\s+/, ""), kind: "item" };
      return;
    }
    if (t.startsWith(">")) {
      flush();
      return;
    }
    if (!para) para = { line: i + 1, text: "", kind: "para" };
    para.text += " " + t;
  });
  flush();
  return units;
}

function proseOfZig(text) {
  const units = [];
  let para = null;
  const flush = () => {
    if (para && para.text.trim()) units.push(para);
    para = null;
  };
  text.split("\n").forEach((l, i) => {
    const m = l.match(/^\s*\/\/[!/]?\s?(.*)$/);
    if (!m || /^(title|native|norun|fails|simd|link|cinclude|csource)\b/.test(m[1])) return flush();
    if (!m[1].trim()) return flush();
    if (!para) para = { line: i + 1, text: "", kind: "para" };
    para.text += " " + m[1].replace(/`[^`]*`/g, "CODE");
  });
  flush();
  return units;
}

function sentences(text) {
  return text
    .split(/(?<=[.?!])\s+(?=[A-Z0-9`"(])|(?<=:)\s+(?=[A-Z])/)
    .map((s) => s.trim())
    .filter((s) => s.split(/\s+/).length > 1);
}

function check(file) {
  const text = readFileSync(file, "utf8");
  const units = file.endsWith(".zig") ? proseOfZig(text) : proseOfMdx(text);
  const found = [];
  for (const u of units) {
    const ss = u.kind === "heading" ? [u.text] : sentences(u.text);
    if (u.kind === "para" && ss.length > MAX_SENTENCES) {
      found.push([u.line, "paragraph", `${ss.length} sentences`]);
    }
    for (const s of ss) {
      const words = s.split(/\s+/).length;
      if (words > MAX_WORDS) found.push([u.line, "long", `${words} words: ${s.slice(0, 70)}...`]);
      const ing = ingWords(s);
      if (ing.length) found.push([u.line, "-ing", ing.join(", ")]);
      for (const [name, re, keep] of RULES) {
        const m = s.match(re);
        if (m && (!keep || keep(m))) found.push([u.line, name, m[0]]);
      }
    }
  }
  return found;
}

function walk(p, out) {
  if (statSync(p).isDirectory()) {
    for (const e of readdirSync(p).sort()) walk(join(p, e), out);
  } else if (/\.(mdx|zig)$/.test(p) && !/\/_[^/]*$/.test(p)) {
    out.push(p);
  }
  return out;
}

const args = process.argv.slice(2);
const verbose = args.includes("--verbose");
const strict = args.includes("--strict");
const paths = args.filter((a) => !a.startsWith("--"));
if (!paths.length) {
  console.error("usage: check-ste.mjs [--verbose] [--strict] <file or directory>...");
  process.exit(2);
}

const files = paths.flatMap((p) => walk(p, []));
const totals = {};
let dirty = 0;
for (const f of files) {
  const found = check(f);
  if (!found.length) continue;
  dirty++;
  const counts = {};
  for (const [, rule] of found) {
    counts[rule] = (counts[rule] ?? 0) + 1;
    totals[rule] = (totals[rule] ?? 0) + 1;
  }
  const summary = Object.entries(counts).map(([k, v]) => `${k} ${v}`).join(", ");
  console.log(`${relative(process.cwd(), f)}: ${summary}`);
  if (verbose) for (const [line, rule, what] of found) console.log(`  ${line}: ${rule}: ${what}`);
}
const total = Object.entries(totals).map(([k, v]) => `${k} ${v}`).join(", ");
console.log(`${files.length} files, ${dirty} with findings${total ? ": " + total : ""}`);
process.exit(strict && dirty ? 1 : 0);
