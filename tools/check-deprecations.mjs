// Fail the build when a snippet or a chapter teaches a standard-library name
// that the installed Zig marks deprecated. Used by `zig build verify` and
// available on its own as `zig build deprecations`.
//
//   check-deprecations.mjs <zig-exe> <version> <file>...
//
// Why this exists: a rename like `std.mem.indexOf` -> `std.mem.find` leaves the
// old name behind as an alias that compiles and behaves identically. Nothing
// else in this repo can see that. `zig build verify` stays green, the nightly
// stays green, and the guide teaches a name upstream has moved on from for as
// long as nobody happens to read the std source. That is the one failure mode
// this project cannot tolerate, so it gets a gate.
//
// The deprecation list is not maintained here. It is read out of the std source
// that shipped with the compiler being used, every run.
//
// Output discipline matches run-wasi.mjs: silent on success, everything to
// stderr on failure, non-zero exit.
import { execFileSync } from "node:child_process";
import { readFileSync, readdirSync, statSync } from "node:fs";
import { dirname, join, relative, sep } from "node:path";

const [zigExe, zigVersion, ...files] = process.argv.slice(2);
if (!zigExe || files.length === 0) {
  console.error("usage: check-deprecations.mjs <zig-exe> <version> <file>...");
  process.exit(2);
}

// ---------------------------------------------------------------- std source

// `zig env` prints ZON, not JSON, and `--json` is accepted and silently
// ignored: it exits 0 having printed ZON anyway. `JSON.parse` on that output
// would throw on a perfectly green tree, so parse the one key we need.
function findStdDir() {
  try {
    const zon = execFileSync(zigExe, ["env"], { encoding: "utf8" });
    const match = zon.match(/\.std_dir\s*=\s*"((?:[^"\\]|\\.)*)"/);
    if (match) return match[1].replace(/\\(.)/g, "$1");
    const lib = zon.match(/\.lib_dir\s*=\s*"((?:[^"\\]|\\.)*)"/);
    if (lib) return join(lib[1].replace(/\\(.)/g, "$1"), "std");
  } catch {
    // fall through to the layout guess
  }
  return join(dirname(zigExe), "lib", "std");
}

const stdDir = findStdDir();

function zigFilesUnder(root) {
  const out = [];
  const walk = (dir) => {
    let entries;
    try {
      entries = readdirSync(dir, { withFileTypes: true });
    } catch {
      return;
    }
    for (const entry of entries) {
      const full = join(dir, entry.name);
      if (entry.isDirectory()) walk(full);
      else if (entry.name.endsWith(".zig")) out.push(full);
    }
  };
  walk(root);
  return out;
}

// `mem.zig` -> `std.mem`, `mem/Allocator.zig` -> `std.mem.Allocator`,
// `std.zig` -> `std`. Deriving the namespace from the path is only sound for
// column-0 declarations, which is why everything below insists on those.
function namespaceOf(file) {
  const rel = relative(stdDir, file).replace(/\.zig$/, "");
  if (rel === "std") return "std";
  return "std." + rel.split(sep).join(".");
}

const MULTI_WORD = /[a-z][A-Z]|_/;

// ------------------------------------------------------- the deprecation map

/** fully-qualified name -> { replacement, note, file, line } */
const deprecated = new Map();

function scanStdFile(file, ns, lines) {
  // Column-0 declarations only. An indented `/// Deprecated` decl is a method,
  // whose receiver is a local variable that no amount of text matching can
  // resolve, so those are skipped rather than guessed at.
  const declAt = (i) => /^pub\s+(?:const|fn|var)\s+([A-Za-z_]\w*)/.exec(lines[i]);

  // Every column-0 decl name in this file, so rule 2 can tell an alias of a
  // sibling declaration from a re-export or a plain value.
  const localDecls = new Set();
  for (let i = 0; i < lines.length; i++) {
    const m = declAt(i);
    if (m) localDecls.add(m[1]);
  }

  const aliasTarget = (line) => {
    const m = /^pub\s+const\s+[A-Za-z_]\w*\s*=\s*([A-Za-z_]\w*)\s*;/.exec(line);
    return m && localDecls.has(m[1]) ? m[1] : null;
  };

  let found = 0;

  // Rule 1: documented deprecations.
  for (let i = 0; i < lines.length; i++) {
    if (!/^\s*\/\/\/.*\bDeprecated\b/i.test(lines[i])) continue;

    // Walk past the rest of the doc comment to the declaration it documents.
    let note = "";
    let j = i;
    while (j < lines.length && /^\s*\/\/\//.test(lines[j])) {
      note += " " + lines[j].replace(/^\s*\/\/\/\s?/, "").trim();
      j++;
    }
    const decl = j < lines.length ? declAt(j) : null;
    if (!decl) continue;

    note = note.trim();
    const name = `${ns}.${decl[1]}`;

    // Prefer the alias right-hand side over the prose. std's own suggestion is
    // sometimes wrong: mem.zig says `lastIndexOf` is "deprecated in favor of
    // find" while the declaration reads `= findLast`.
    const rhs = aliasTarget(lines[j]);
    let replacement = rhs ? `${ns}.${rhs}` : null;
    if (!replacement) {
      const quoted = /`(@?[A-Za-z_][\w.]*)`/.exec(note);
      if (quoted && quoted[1].startsWith("@")) {
        // A builtin, e.g. `@memmove`. It has no namespace to resolve against.
        replacement = quoted[1];
      } else if (quoted) {
        // A bare name in the prose means "a sibling in this file", so it
        // resolves against the declaring namespace: `SafeAllocator` in heap.zig
        // is std.heap.SafeAllocator, not std.SafeAllocator. A dotted one is
        // already rooted at std.
        replacement = quoted[1].startsWith("std.")
          ? quoted[1]
          : quoted[1].includes(".")
            ? `std.${quoted[1]}`
            : `${ns}.${quoted[1]}`;
      }
    }

    deprecated.set(name, { replacement, note, file, line: j + 1 });
    found++;
    i = j;
  }

  // Rule 2: aliases carrying no doc comment at all. Three real ones live in
  // std.mem (indexOfMax, indexOfNonePos, indexOfPosLinear). Applied to all of
  // std this rule is noise: it flags Random.DefaultPrng and every C typedef.
  // Restricting it to files that already contain a documented deprecation
  // brings the whole tree down to a handful of hits, all of them real.
  if (found === 0) return;
  for (let i = 0; i < lines.length; i++) {
    const decl = declAt(i);
    if (!decl) continue;
    const name = `${ns}.${decl[1]}`;
    if (deprecated.has(name)) continue;
    const rhs = aliasTarget(lines[i]);
    if (!rhs || rhs === decl[1]) continue;
    deprecated.set(name, {
      replacement: `${ns}.${rhs}`,
      note: "undocumented alias",
      file,
      line: i + 1,
    });
  }
}

for (const file of zigFilesUnder(stdDir)) {
  let lines;
  try {
    lines = readFileSync(file, "utf8").split("\n");
  } catch {
    continue;
  }
  scanStdFile(file, namespaceOf(file), lines);
}

// Rule 3: the generated builtin module. `@import("builtin")` is not a file in
// std, so the walk above cannot see it, and it currently carries a live alias
// (`mode` = `optimize`) that the guide uses.
try {
  const builtin = execFileSync(zigExe, ["build-exe", "--show-builtin"], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "ignore"],
  }).split("\n");
  const declared = new Set();
  for (const line of builtin) {
    const m = /^pub\s+const\s+([A-Za-z_]\w*)/.exec(line);
    if (m) declared.add(m[1]);
  }
  for (let i = 0; i < builtin.length; i++) {
    const m = /^pub\s+const\s+([A-Za-z_]\w*)\s*=\s*([A-Za-z_]\w*)\s*;/.exec(builtin[i]);
    if (!m || m[1] === m[2] || !declared.has(m[2])) continue;
    deprecated.set(`builtin.${m[1]}`, {
      replacement: `builtin.${m[2]}`,
      note: "alias in the generated builtin module",
      file: "@import(\"builtin\")",
      line: i + 1,
    });
  }
} catch {
  // A compiler that will not print its builtin module is a problem the rest of
  // the build will report far more clearly than this check would.
}

// A leaf name may stand in for its full path in prose only when it is
// unambiguous. Single-word leaves (`path`, `pop`, `dupe`, `mode`) collide with
// ordinary English and with unrelated current APIs, so they never match bare.
const leafOwners = new Map();
for (const [name, info] of deprecated) {
  const leaf = name.slice(name.lastIndexOf(".") + 1);
  if (!leafOwners.has(leaf)) leafOwners.set(leaf, []);
  leafOwners.get(leaf).push([name, info]);
}
const bareLeaf = new Map();
for (const [leaf, owners] of leafOwners) {
  if (owners.length === 1 && MULTI_WORD.test(leaf)) bareLeaf.set(leaf, owners[0]);
}

// ------------------------------------------------------------------ matching

const problems = [];

function suggestion(info) {
  return info.replacement ?? "see the note below";
}

function report(file, line, col, text, symbol, info, extra) {
  problems.push({ file, line, col, text, symbol, info, extra });
}

// Does `haystack` name the current symbol as well as the old one? When the
// replacement's leaf is a single common word, requiring the bare leaf would be
// satisfied by almost any page, so require it the way std writes it.
function namesReplacement(haystack, info) {
  if (!info.replacement) return true; // nothing to point at; the note has to do
  const parts = info.replacement.split(".");
  const leaf = parts[parts.length - 1];
  const needle = MULTI_WORD.test(leaf) ? leaf : parts.slice(-2).join(".");
  return haystack.includes(needle);
}

// --- .zig -------------------------------------------------------------------

function checkZig(file, source) {
  const lines = source.split("\n");

  // `//! deprecated: std.heap.DebugAllocator` exempts a snippet that shows an
  // old name on purpose. It has to name the fully-qualified symbol, and an
  // exemption for a symbol the file no longer uses is itself an error, so a
  // stale one cannot outlive the line it was covering.
  const exempt = new Set();
  for (const line of lines) {
    const m = /^\s*\/\/!\s*deprecated:(.*)$/.exec(line);
    if (!m) continue;
    for (const tok of m[1].split(/[\s,]+/)) if (tok) exempt.add(tok);
  }
  const used = new Set();

  // Local aliases, so `const mem = std.mem; mem.indexOf(...)` still resolves.
  const aliases = new Map();
  for (const line of lines) {
    const m = /^\s*(?:pub\s+)?const\s+([A-Za-z_]\w*)\s*=\s*(std(?:\.[A-Za-z_]\w*)*)\s*;/.exec(line);
    if (m) aliases.set(m[1], m[2]);
  }

  const heads = ["std", ...aliases.keys()].map((h) => h.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"));
  const pattern = new RegExp(`\\b(${heads.join("|")})((?:\\.[A-Za-z_]\\w*)+)`, "g");

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (/^\s*\/\/!/.test(line)) continue;
    // A `//` comment in a snippet is prose the reader sees, so it follows the
    // same rule the chapters do: it may name an old symbol as long as the file
    // also uses the current one. Naming the old spelling is how CLAUDE.md says
    // to teach a rename, and that has to stay possible next to the code.
    const isComment = /^\s*\/\//.test(line);
    for (const m of line.matchAll(pattern)) {
      const head = aliases.get(m[1]) ?? m[1];
      const full = head + m[2];
      // Try the longest resolved path first, then each prefix: a deprecated
      // type used as `std.heap.DebugAllocator(.{})` still has to be caught.
      const parts = full.split(".");
      for (let n = parts.length; n >= 2; n--) {
        const candidate = parts.slice(0, n).join(".");
        const info = deprecated.get(candidate);
        if (!info) continue;
        used.add(candidate);
        if (exempt.has(candidate)) break;
        if (isComment && namesReplacement(source, info)) break;
        report(file, i + 1, m.index + 1, line, candidate, info);
        break;
      }
    }
  }

  for (const symbol of exempt) {
    if (used.has(symbol)) continue;
    problems.push({
      file,
      line: 1,
      col: 1,
      text: null,
      symbol,
      info: null,
      extra:
        `exempted with \`//! deprecated: ${symbol}\` but the file does not use it.\n` +
        `  Remove the directive. An exemption must not outlive the line it covered.`,
    });
  }
}

// --- .mdx -------------------------------------------------------------------

// Prose cannot be resolved semantically, so the rule is the editorial one
// CLAUDE.md already states: a page may name an old symbol as long as it also
// names the current one. That is what makes the delta sections legal and a
// silent stale mention not.
function checkMdx(file, source) {
  const lines = source.split("\n");

  // Only code spans, fenced blocks, and the frontmatter description. Bare prose
  // is never matched; too many std leaf names are ordinary English words.
  const regions = [];
  let inFence = false;
  let inFrontmatter = false;
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (i === 0 && line.trim() === "---") {
      inFrontmatter = true;
      continue;
    }
    if (inFrontmatter) {
      if (line.trim() === "---") inFrontmatter = false;
      else if (/^description:/.test(line)) regions.push([i, line]);
      continue;
    }
    if (/^\s*```/.test(line)) {
      inFence = !inFence;
      continue;
    }
    if (inFence) {
      regions.push([i, line]);
      continue;
    }
    for (const m of line.matchAll(/`([^`]+)`/g)) regions.push([i, m[1]]);
  }

  const named = new Set();
  const hits = [];
  for (const [i, text] of regions) {
    for (const m of text.matchAll(/\b(?:std\.)?([A-Za-z_][\w.]*)\b/g)) {
      const qualified = m[0].startsWith("std.") ? m[0] : null;
      if (qualified && deprecated.has(qualified)) {
        hits.push([i, qualified, deprecated.get(qualified), text]);
        continue;
      }
      const leaf = m[1].includes(".") ? m[1].slice(m[1].lastIndexOf(".") + 1) : m[1];
      const owner = bareLeaf.get(leaf);
      if (owner && !qualified) hits.push([i, owner[0], owner[1], text]);
    }
    named.add(text);
  }

  const haystack = regions.map(([, text]) => text).join("\n");

  for (const [i, symbol, info, text] of hits) {
    if (namesReplacement(haystack, info)) continue;
    const parts = info.replacement.split(".");
    const leaf = parts[parts.length - 1];
    const needle = MULTI_WORD.test(leaf) ? leaf : parts.slice(-2).join(".");
    report(file, i + 1, 1, text, symbol, info, `names \`${symbol}\` without naming \`${needle}\``);
  }
}

// ----------------------------------------------------------------------- run

for (const file of files) {
  let source;
  try {
    source = readFileSync(file, "utf8");
  } catch {
    continue;
  }
  if (file.endsWith(".zig")) checkZig(file, source);
  else if (file.endsWith(".mdx")) checkMdx(file, source);
}

if (problems.length > 0) {
  const out = [];
  for (const p of problems) {
    if (p.info === null) {
      out.push(`${p.file}: error: ${p.extra}\n`);
      continue;
    }
    const headline = p.extra ?? `${p.symbol} is deprecated`;
    out.push(`${p.file}:${p.line}:${p.col}: error: ${headline}`);
    if (p.text) {
      out.push(`    ${p.text.trim()}`);
    }
    out.push(`  use ${suggestion(p.info)}`);
    if (p.info.note) {
      const where = p.info.file.startsWith("@")
        ? p.info.file
        : relative(stdDir, p.info.file);
      out.push(`  ${where}:${p.info.line}: ${p.info.note}`);
    }
    out.push("");
  }

  const zigFiles = new Set(problems.filter((p) => p.file.endsWith(".zig")).map((p) => p.file));
  const mdxFiles = new Set(problems.filter((p) => p.file.endsWith(".mdx")).map((p) => p.file));
  const zigHits = problems.filter((p) => p.file.endsWith(".zig")).length;
  const mdxHits = problems.filter((p) => p.file.endsWith(".mdx")).length;

  out.push(
    `${zigHits} deprecated ${zigHits === 1 ? "symbol" : "symbols"} in ${zigFiles.size} ` +
      `${zigFiles.size === 1 ? "file" : "files"}, ${mdxHits} in ${mdxFiles.size} ` +
      `${mdxFiles.size === 1 ? "chapter" : "chapters"}.`,
  );
  out.push(`Checked against Zig ${zigVersion ?? "?"}, std at ${stdDir}.`);
  out.push("To show an old name on purpose, add `//! deprecated: <symbol>` to the snippet.");
  out.push("A chapter may name an old symbol only if it also names the current one.");
  process.stderr.write(out.join("\n") + "\n");
  process.exit(1);
}
