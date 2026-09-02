/**
 * Every URL this site has ever served, and where that page lives now.
 *
 * The guide has been reorganised three times, and each time the old addresses
 * were left to rot. Search Console found the result: `/optionals/`,
 * `/cookbook/parallel-sum/`, `/building-libraries/orm/adapters/` and about
 * three hundred more returning 404, taking with them every link anyone had
 * shared and every position those pages had earned. This module is the record
 * of those moves, and `astro.config.mjs` turns it into a redirect for each one.
 *
 * GitHub Pages serves static files and cannot issue a 301, so Astro emits a
 * small HTML page per old address carrying `<meta http-equiv="refresh">` at
 * zero delay and a canonical link to the destination. Google treats that as a
 * redirect and passes the signals on. It is the only mechanism this host has.
 *
 * Astro's template also carries `<meta name="robots" content="noindex">`, and
 * that tag is stripped after the build by plugins/indexable-redirects.mjs.
 * Read that file before putting it back: on a host that could issue a 301 the
 * tag would never be seen, but here the body is the redirect, and telling
 * Google not to index the page is telling it to drop the address rather than
 * pass on what the address earned.
 *
 * Two rules build the map, and the second overrides the first:
 *
 * 1. Every page currently in the guide was once at the same path without the
 *    `/learn/` prefix, because the guide used to sit at the root. That rule is
 *    mechanical and is derived from the content directory rather than listed,
 *    so a chapter added tomorrow gets its redirect without anyone remembering.
 * 2. `MOVED` and `MOVED_INDEXES` below are the pages that also changed
 *    directory. Those are history and cannot be derived from anything; git
 *    would know, but CI clones are shallow and a redirect that disappears
 *    because a clone was cheap is worse than no redirect at all.
 *
 * The destinations are checked against the content directory at build time, so
 * a chapter that moves again without an entry here fails the build rather than
 * pointing readers at a 404 that nothing would ever notice.
 */
import { readdirSync } from "node:fs";
import { fileURLToPath } from "node:url";

const DOCS = fileURLToPath(new URL("./src/content/docs", import.meta.url));

/**
 * Chapters that changed directory, old id to current id.
 *
 * Three generations, oldest first. The flat block is from before sections
 * existed at all, when a chapter was a single word at the root. The `cookbook`
 * and `building-libraries` blocks are the renames that followed: the Cookbook
 * section became How-To, and the ORM stopped being a group inside Building
 * Libraries and became a section of its own. The last few are chapters that
 * changed section rather than the section changing name, which is why three
 * recipes now answer to a Networking address and three more sit one directory
 * deeper under `databases`.
 */
export const MOVED = {
  allocators: "standard-library/allocators",
  "anonymous-structs": "language-basics/anonymous-structs",
  arrays: "language-basics/arrays",
  assignment: "language-basics/assignment",
  comptime: "language-basics/comptime",
  defer: "language-basics/defer",
  enums: "language-basics/enums",
  errors: "language-basics/errors",
  floats: "language-basics/floats",
  "for-loops": "language-basics/for-loops",
  functions: "language-basics/functions",
  "hello-world": "getting-started/hello-world",
  "if-expressions": "language-basics/if-expressions",
  imports: "language-basics/imports",
  "inline-loops": "language-basics/inline-loops",
  "integer-rules": "language-basics/integer-rules",
  "labelled-blocks": "language-basics/labelled-blocks",
  "labelled-loops": "language-basics/labelled-loops",
  "loops-as-expressions": "language-basics/loops-as-expressions",
  "many-item-pointers": "language-basics/many-item-pointers",
  opaque: "language-basics/opaque",
  optionals: "language-basics/optionals",
  "payload-captures": "language-basics/payload-captures",
  "pointer-sized-integers": "language-basics/pointer-sized-integers",
  pointers: "language-basics/pointers",
  "runtime-safety": "language-basics/runtime-safety",
  "sentinel-termination": "language-basics/sentinel-termination",
  slices: "language-basics/slices",
  structs: "language-basics/structs",
  switch: "language-basics/switch",
  unions: "language-basics/unions",
  vectors: "language-basics/vectors",
  "while-loops": "language-basics/while-loops",

  "cookbook/binary-roundtrip": "how-to/binary-roundtrip",
  "cookbook/bitsets": "how-to/bitsets",
  "cookbook/catching-leaks": "how-to/catching-leaks",
  "cookbook/checked-math": "how-to/checked-math",
  "cookbook/http-roundtrip": "networking/http-roundtrip",
  "cookbook/json-config": "how-to/json-config",
  "cookbook/parallel-sum": "how-to/parallel-sum",
  "cookbook/ring-buffer": "how-to/ring-buffer",
  "cookbook/seeded-random": "how-to/seeded-random",
  "cookbook/simd-scan": "how-to/simd-scan",
  "cookbook/simd-sum": "how-to/simd-sum",
  "cookbook/struct-printer": "how-to/struct-printer",
  "cookbook/tcp-echo": "networking/tcp-echo",
  "cookbook/udp-message": "networking/udp-message",
  "cookbook/word-frequency": "how-to/word-frequency",
  "cookbook/work-index": "how-to/work-index",
  "cookbook/worker-queue": "how-to/worker-queue",

  "building-libraries/orm/adapters": "orm/adapters",
  "building-libraries/orm/insert-update": "orm/insert-update",
  "building-libraries/orm/migrations": "orm/migrations",
  "building-libraries/orm/query-builder": "orm/query-builder",
  "building-libraries/orm/repo": "orm/repo",
  "building-libraries/orm/schema-to-sql": "orm/schema-to-sql",
  "building-libraries/orm/transactions": "orm/transactions",
  "building-libraries/orm/validation-rules": "orm/validation-rules",
  "building-libraries/orm/what-is-ecto": "orm/what-is-ecto",

  "how-to/http-roundtrip": "networking/http-roundtrip",
  "how-to/postgres-wire": "how-to/databases/postgres-wire",
  "how-to/redis-resp": "how-to/databases/redis-resp",
  "how-to/sqlite-basic": "how-to/databases/sqlite-basic",
  "how-to/tcp-echo": "networking/tcp-echo",
  "how-to/udp-message": "networking/udp-message",
};

/**
 * Section and group index pages that moved, old id to current id.
 *
 * `building-libraries` has no successor of its own: it became the Projects
 * track, and a track is never a URL segment. Its readers wanted the ORM, so
 * that is where they go.
 */
export const MOVED_INDEXES = {
  cookbook: "how-to",
  "building-libraries": "orm",
  "building-libraries/orm": "orm",
};

/**
 * Top-level paths that belong to something other than a chapter. A redirect
 * whose source matched one of these would replace the real page: Astro drops
 * the file-based route in favour of the redirect, and the page would vanish
 * with the build still green.
 */
const RESERVED = new Set([
  "learn",
  "paths",
  "about",
  "contact",
  "privacy",
  "references",
  "verification",
  "whats-new",
]);

/** Every chapter id in the guide, from the files rather than from a list. */
function chapterIds() {
  return readdirSync(DOCS, { recursive: true, encoding: "utf8" })
    .filter((entry) => entry.endsWith(".mdx"))
    .map((entry) => entry.replaceAll("\\", "/").slice(0, -".mdx".length));
}

/**
 * Every index page id: a section directory, and any group directory inside
 * one. Neither has a source file, so the directories the chapters sit in are
 * the only place this can come from, which is also what `[...slug].astro`
 * generates the pages from.
 */
function indexIds(chapters) {
  const dirs = new Set();
  for (const id of chapters) {
    const parts = id.split("/");
    for (let depth = 1; depth < parts.length; depth++) {
      dirs.add(parts.slice(0, depth).join("/"));
    }
  }
  return [...dirs];
}

/**
 * The redirect table Astro takes: source path (no base, Astro prepends it) to
 * destination path (base included, because Astro resolves a destination that
 * matches no route of its own verbatim).
 */
export function legacyRedirects(base) {
  const chapters = chapterIds();
  const indexes = indexIds(chapters);
  const live = new Set([...chapters, ...indexes]);

  const redirects = {};
  const add = (from, to) => {
    if (RESERVED.has(from.split("/")[0])) {
      throw new Error(
        `Legacy redirect /${from}/ would shadow a page that is not a chapter. ` +
          `Rename the section, or drop the entry from RESERVED in legacy-urls.mjs ` +
          `if that page is gone.`,
      );
    }
    redirects[`/${from}`] = `${base}learn/${to}/`;
  };

  // Rule 1: the guide used to sit at the root.
  for (const id of [...indexes, ...chapters]) add(id, id);

  // Rule 2: and before that, some of it sat somewhere else again.
  for (const [table, valid] of [
    [MOVED, new Set(chapters)],
    [MOVED_INDEXES, new Set(indexes)],
  ]) {
    for (const [from, to] of Object.entries(table)) {
      if (!valid.has(to)) {
        throw new Error(
          `Legacy redirect /${from}/ points at /learn/${to}/, which is not a page. ` +
            `A chapter moved without its entry in legacy-urls.mjs being updated.`,
        );
      }
      if (live.has(from)) {
        throw new Error(
          `Legacy redirect /${from}/ is also a live page at /learn/${from}/. ` +
            `One of the two has to give: an address cannot be both.`,
        );
      }
      add(from, to);
    }
  }

  return redirects;
}
