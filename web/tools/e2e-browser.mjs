/**
 * End-to-end check of the built site in a real browser.
 *
 * `zig build verify` proves the snippets run under Node's WASI. This proves
 * the other half: that the published pages actually execute them in a browser,
 * that compile-only snippets render without a Run button, and that every
 * internal link resolves.
 *
 *   npm run e2e --prefix web            # serves web/dist itself
 *   npm run e2e --prefix web <baseUrl>  # tests an already-running server
 */
import { chromium } from "playwright";
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { join, extname, dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const DIST = resolve(dirname(fileURLToPath(import.meta.url)), "..", "dist");

const TYPES = {
  ".html": "text/html",
  ".js": "text/javascript",
  ".css": "text/css",
  ".json": "application/json",
  ".wasm": "application/wasm",
  ".svg": "image/svg+xml",
};

// For a GitHub Pages project site the build embeds a path prefix in every
// absolute URL, so the test server has to mount `dist` under that same prefix
// or every link 404s.
const PREFIX = (process.env.BASE_PATH ?? "/").replace(/\/+$/, "");

/** Minimal static server so the test has no external dependency to orchestrate. */
async function serve(root) {
  const server = createServer(async (req, res) => {
    let path = decodeURIComponent(new URL(req.url, "http://x").pathname);
    if (PREFIX) {
      // Must be strict: GitHub Pages serves a project site ONLY under its
      // prefix. Accepting unprefixed paths here would let a link that 404s in
      // production pass locally — which is exactly what happened once.
      if (path !== PREFIX && !path.startsWith(`${PREFIX}/`)) {
        res.writeHead(404).end("not found");
        return;
      }
      path = path.slice(PREFIX.length) || "/";
    }
    // Directory URLs map to their index.html, matching the deployed layout.
    const file = join(root, path.endsWith("/") ? `${path}index.html` : path);
    try {
      const body = await readFile(file);
      res.writeHead(200, { "content-type": TYPES[extname(file)] ?? "application/octet-stream" });
      res.end(body);
    } catch {
      res.writeHead(404).end("not found");
    }
  });
  await new Promise((ok) => server.listen(0, ok));
  return { server, url: `http://localhost:${server.address().port}` };
}

const given = process.argv[2] ?? process.env.BASE;
const hosted = given ? null : await serve(DIST);
const BASE = (given ?? hosted.url).replace(/\/$/, "");

const browser = await chromium.launch();
const page = await browser.newPage();

// Stub the ad network out. Its script is third-party and non-deterministic:
// left live it would make every `networkidle` wait on an ad auction, and its
// own console noise would fail a gate that exists to test the snippets. An
// empty 200 rather than an abort, because a blocked request is itself logged
// as a console error.
await page.route(
  /(googlesyndication|googletagservices|googleadservices|doubleclick)\.(com|net)/,
  (route) => route.fulfill({ status: 200, contentType: "text/javascript", body: "" }),
);

const consoleErrors = new Set();
page.on("pageerror", (e) => consoleErrors.add(`pageerror: ${e.message}`));
page.on("console", (m) => {
  if (m.type() === "error") consoleErrors.add(`console: ${m.text()}`);
});

await page.goto(`${BASE}${PREFIX}/`, { waitUntil: "networkidle" });
const chapters = await page.$$eval(".sidebar a", (as) => as.map((a) => a.getAttribute("href")));
if (chapters.length === 0) {
  console.error("No chapters found in the sidebar — is the site built?");
  process.exit(2);
}

const failures = [];
const internalLinks = new Set();
const visited = new Set();
let playgrounds = 0;
let compileOnly = 0;

/**
 * What a crawler and a link preview read. None of it is visible on the page,
 * so a missing canonical or an empty description would never be noticed by
 * looking at the site — exactly the failure mode this gate exists for.
 */
async function checkHead(href) {
  const head = await page.evaluate(() => ({
    title: document.title,
    description: document.querySelector('meta[name="description"]')?.content ?? "",
    canonical: document.querySelector('link[rel="canonical"]')?.href ?? "",
    ogTitle: document.querySelector('meta[property="og:title"]')?.content ?? "",
    ogImage: document.querySelector('meta[property="og:image"]')?.content ?? "",
    jsonLd: [...document.querySelectorAll('script[type="application/ld+json"]')].map(
      (s) => s.textContent,
    ),
    h1: document.querySelectorAll("h1").length,
  }));

  if (!head.title.trim()) failures.push(`${href} has no <title>`);
  if (!head.description.trim()) failures.push(`${href} has no meta description`);
  if (!head.ogTitle.trim()) failures.push(`${href} has no og:title`);
  if (!head.ogImage.trim()) failures.push(`${href} has no og:image`);
  if (head.h1 !== 1) failures.push(`${href} has ${head.h1} <h1> elements, want exactly 1`);

  // The canonical must name this page. A layout that emitted one fixed URL
  // would tell Google every chapter is a duplicate of the home page.
  if (!head.canonical) {
    failures.push(`${href} has no canonical link`);
  } else if (new URL(head.canonical).pathname !== new URL(BASE + href).pathname) {
    failures.push(`${href} canonical points at ${new URL(head.canonical).pathname}`);
  }

  if (head.jsonLd.length !== 1) {
    failures.push(`${href} has ${head.jsonLd.length} JSON-LD blocks, want exactly 1`);
  }
  for (const block of head.jsonLd) {
    try {
      const parsed = JSON.parse(block);
      const types = (parsed["@graph"] ?? []).map((n) => n["@type"]);
      if (!types.includes("BreadcrumbList")) {
        failures.push(`${href} JSON-LD has no BreadcrumbList`);
      }
    } catch (e) {
      failures.push(`${href} JSON-LD is not valid JSON: ${e.message}`);
    }
  }

  visited.add(new URL(BASE + href).pathname);
}

for (const href of chapters) {
  const response = await page.goto(BASE + href, { waitUntil: "networkidle" });
  if (!response || !response.ok()) {
    failures.push(`${href} -> HTTP ${response?.status() ?? "no response"}`);
    continue;
  }
  await checkHead(href);
  compileOnly += await page.locator(".pg-static").count();

  for (const link of await page.$$eval("main a[href^='/']", (as) =>
    as.map((a) => a.getAttribute("href")),
  )) {
    internalLinks.add(link);
  }

  const blocks = page.locator("zig-playground");
  const count = await blocks.count();

  for (let i = 0; i < count; i++) {
    const block = blocks.nth(i);
    const name = await block.getAttribute("data-name");
    playgrounds++;

    await block.locator("button.pg-run").click();
    await block.locator(".pg-output").waitFor({ state: "visible", timeout: 30000 });
    // The status still reads "running…" until the run settles.
    await page.waitForFunction(
      (idx) =>
        !document
          .querySelectorAll("zig-playground")
          [idx].querySelector(".pg-status")
          .textContent.includes("ing…"),
      i,
      { timeout: 30000 },
    );

    const status = (await block.locator(".pg-status").textContent()).trim();
    if (!status.startsWith("exit 0")) {
      const output = (await block.locator(".pg-output").textContent()).trim();
      failures.push(`${href} [${name}] ${status}\n${output}`);
    }
  }
}

// The pages outside the chapter list still have to carry correct metadata.
for (const href of [`${PREFIX}/`, `${PREFIX}/privacy/`]) {
  const res = await page.goto(BASE + href, { waitUntil: "domcontentloaded" });
  if (!res?.ok()) {
    failures.push(`${href} -> HTTP ${res?.status() ?? "no response"}`);
    continue;
  }
  await checkHead(href);
}

let brokenLinks = 0;
for (const href of internalLinks) {
  const res = await page.request.get(BASE + href);
  if (!res.ok()) {
    brokenLinks++;
    failures.push(`broken link ${href} -> HTTP ${res.status()}`);
  }
}

/**
 * The sitemap is generated from the content collection, so it cannot list a
 * page that does not exist — but it can silently *omit* one, which is how a
 * whole section stays unindexed with nothing failing. Assert both directions:
 * every page this run reached is listed, and everything listed resolves.
 */
const sitemapRes = await page.request.get(`${BASE}${PREFIX}/sitemap.xml`);
let sitemapCount = 0;
if (!sitemapRes.ok()) {
  failures.push(`sitemap.xml -> HTTP ${sitemapRes.status()}`);
} else {
  const locs = [...(await sitemapRes.text()).matchAll(/<loc>([^<]+)<\/loc>/g)].map((m) => m[1]);
  sitemapCount = locs.length;
  const listed = new Set(locs.map((loc) => new URL(loc).pathname));

  for (const path of visited) {
    if (!listed.has(path)) failures.push(`${path} is not listed in sitemap.xml`);
  }
  for (const path of listed) {
    const res = await page.request.get(BASE + path);
    if (!res.ok()) failures.push(`sitemap entry ${path} -> HTTP ${res.status()}`);
  }
}

// robots.txt has to point at the sitemap that exists, on the origin the site
// is actually deployed to.
const robotsRes = await page.request.get(`${BASE}${PREFIX}/robots.txt`);
if (!robotsRes.ok()) {
  failures.push(`robots.txt -> HTTP ${robotsRes.status()}`);
} else {
  const robots = await robotsRes.text();
  const sitemapLine = robots.match(/^Sitemap:\s*(\S+)$/m);
  if (!sitemapLine) {
    failures.push("robots.txt has no Sitemap: line");
  } else if (new URL(sitemapLine[1]).pathname !== `${PREFIX}/sitemap.xml`) {
    failures.push(
      `robots.txt points at ${new URL(sitemapLine[1]).pathname}, want ${PREFIX}/sitemap.xml`,
    );
  }
  if (/^Disallow:\s*\/\s*$/m.test(robots)) {
    failures.push("robots.txt disallows the whole site");
  }
}

// The preview card is referenced by absolute URL from every page; a rename
// would leave every share on every network showing a blank rectangle.
const ogRes = await page.request.get(`${BASE}${PREFIX}/og.png`);
if (!ogRes.ok()) failures.push(`og.png -> HTTP ${ogRes.status()}`);

await browser.close();
hosted?.server.close();

console.log(
  `pages: ${chapters.length}  playgrounds: ${playgrounds}  ` +
    `compile-only: ${compileOnly}  links: ${internalLinks.size}  ` +
    `broken: ${brokenLinks}  sitemap: ${sitemapCount}  ` +
    `console errors: ${consoleErrors.size}`,
);

// A run that exercised nothing must not report success — that would turn a
// broken base path or a missing bundle into a green build.
if (playgrounds === 0) {
  failures.push(
    `no playgrounds were exercised across ${chapters.length} pages — ` +
      `the site is probably not being served at the expected path ` +
      `(BASE_PATH=${JSON.stringify(PREFIX)})`,
  );
}

if (failures.length || consoleErrors.size) {
  console.error("\nFailures:");
  for (const f of failures) console.error(`  ${f}`);
  for (const e of consoleErrors) console.error(`  ${e}`);
  process.exit(1);
}

console.log("All playgrounds ran, all links resolved, no console errors.");
