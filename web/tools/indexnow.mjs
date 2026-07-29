/**
 * Tell IndexNow which URLs this deploy changed.
 *
 * Reads changed file paths on stdin (what `git diff --name-only` prints), maps
 * the ones that are content to their URLs, and submits that list. Google does
 * not participate; Bing, Yandex, Seznam and Naver do, and Bing is what ChatGPT
 * search reads.
 *
 *   git diff --name-only A B | node tools/indexnow.mjs
 *   git diff --name-only A B | node tools/indexnow.mjs --dry-run
 *
 * Submits *only what changed*, deliberately. Pushing all 145 URLs on every
 * nightly would be a false claim about 145 pages and the documented way to have
 * a host's submissions throttled or ignored. A run with nothing to say exits 0
 * without calling anything, which is the normal outcome of a nightly that found
 * no drift.
 *
 * Never fails the build. This is a notification, not a gate: the sitemap still
 * lists every page and the site is already published by the time this runs, so
 * a 500 from someone else's API must not turn a good deploy red.
 */
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));

// Read out of the TypeScript module rather than importing it. `src/indexnow.ts`
// is the one place the key is written and both this and the served `/<key>.txt`
// have to agree with it, but importing a `.ts` from a `.mjs` would rest on
// Node's type stripping being on, which is a runtime detail this script has no
// reason to depend on. The constant is a bare string literal; a regex is enough.
const source = readFileSync(resolve(HERE, "../src/indexnow.ts"), "utf8");
const INDEXNOW_KEY = source.match(/INDEXNOW_KEY\s*=\s*"([a-f0-9]+)"/)?.[1];
if (!INDEXNOW_KEY) {
  console.log("indexnow: could not read INDEXNOW_KEY from src/indexnow.ts, skipping.");
  process.exit(0);
}

const DRY = process.argv.includes("--dry-run");
const SITE = (process.env.SITE_URL ?? "https://www.ziglang.in").replace(/\/$/, "");
const BASE = (process.env.BASE_PATH ?? "/").replace(/\/+$/, "");
const GUIDE = "learn";

if (process.stdin.isTTY) {
  console.error("usage: git diff --name-only <a> <b> | node tools/indexnow.mjs [--dry-run]");
  process.exit(2);
}
const changed = readFileSync(0, "utf8")
  .split("\n")
  .map((l) => l.trim())
  .filter(Boolean);

const urls = new Set();

for (const path of changed) {
  // A chapter: web/src/content/docs/<section>/[<group>/]<name>.mdx
  const chapter = path.match(/^web\/src\/content\/docs\/(.+)\.mdx?$/);
  if (chapter) {
    urls.add(`${SITE}${BASE}/${GUIDE}/${chapter[1]}/`);
    // Every index above it lists it, so those changed too: the section, plus
    // the group index when the chapter sits one directory deeper (the database
    // recipes, and each library under Building Libraries).
    const parts = chapter[1].split("/");
    for (let i = 1; i < parts.length; i++) {
      urls.add(`${SITE}${BASE}/${GUIDE}/${parts.slice(0, i).join("/")}/`);
    }
    continue;
  }

  // A standalone page: web/src/pages/<name>.astro. The catch-all is the
  // chapter route, already covered above by the content files themselves.
  const page = path.match(/^web\/src\/pages\/([a-z0-9-]+)\.astro$/);
  if (page) {
    urls.add(page[1] === "index" ? `${SITE}${BASE}/` : `${SITE}${BASE}/${page[1]}/`);
    continue;
  }

  // A snippet is content: it is the code shown on whichever chapter embeds it.
  // Mapping snippet to chapter would need the manifest and the MDX; the guide
  // index is a truthful, cheap stand-in that gets the crawler moving.
  if (/^snippets\/.+\.zig$/.test(path)) urls.add(`${SITE}${BASE}/${GUIDE}/`);
}

if (urls.size === 0) {
  console.log("indexnow: nothing content-shaped changed, submitting nothing.");
  process.exit(0);
}

// The API caps a submission at 10,000 URLs, far above anything a single push
// to this repo produces; no batching needed.
const payload = {
  host: new URL(SITE).host,
  key: INDEXNOW_KEY,
  // Under the base path, which is where the build emits it. A key file in a
  // subdirectory authorises only URLs beneath that directory, and every URL
  // this site has is beneath it, so the two stay consistent on a project site
  // as well as on the custom domain at the root.
  keyLocation: `${SITE}${BASE}/${INDEXNOW_KEY}.txt`,
  urlList: [...urls],
};

console.log(`indexnow: ${urls.size} URL(s)`);
for (const u of payload.urlList) console.log(`  ${u}`);

if (DRY) {
  console.log("indexnow: --dry-run, not submitting.");
  process.exit(0);
}

try {
  const res = await fetch("https://api.indexnow.org/indexnow", {
    method: "POST",
    headers: { "content-type": "application/json; charset=utf-8" },
    body: JSON.stringify(payload),
  });
  // 200 accepted, 202 accepted but key still being validated. Anything else is
  // worth printing and worth ignoring.
  console.log(`indexnow: HTTP ${res.status} ${res.statusText}`);
  if (!res.ok) console.log(await res.text().catch(() => ""));
} catch (e) {
  console.log(`indexnow: submission failed, ignoring: ${e.message}`);
}
