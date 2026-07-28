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

// Stub the ad network and analytics out. Both are third-party and
// non-deterministic: left live they would make every `networkidle` wait on an
// ad auction or a beacon, their own console noise would fail a gate that
// exists to test the snippets, and every gate run would report itself as
// traffic. An empty 200 rather than an abort, because a blocked request is
// itself logged as a console error.
await page.route(
  /(googlesyndication|googletagservices|googleadservices|doubleclick|googletagmanager|google-analytics)\.(com|net)/,
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
const pagers = new Map();
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

/**
 * The sidebar has to show you where you are. Opening the current section is
 * only half of it: the sidebar is its own scroll container, so on a page far
 * down the list the active link can sit below the fold and the reader arrives
 * looking at whatever the previous page left on screen. Nothing else here
 * would catch that, because every link still resolves and the page still
 * renders. Also assert the document did not scroll, which is how this would
 * break if someone reached for `scrollIntoView`.
 */
async function checkSidebarSync(href) {
  const state = await page.evaluate(() => {
    const sidebar = document.querySelector(".sidebar");
    const link = sidebar?.querySelector('a[aria-current="page"]');
    if (!sidebar || !link) return null;
    const top = link.getBoundingClientRect().top - sidebar.getBoundingClientRect().top;
    return {
      visible: top >= 0 && top + link.offsetHeight <= sidebar.clientHeight,
      top: Math.round(top),
      height: sidebar.clientHeight,
      pageScrollY: Math.round(window.scrollY),
    };
  });

  if (!state) {
    failures.push(`${href} has no sidebar link marked aria-current="page"`);
    return;
  }
  if (!state.visible) {
    failures.push(
      `${href} sidebar did not scroll its active link into view ` +
        `(at ${state.top}px in a ${state.height}px sidebar)`,
    );
  }
  if (state.pageScrollY !== 0) {
    failures.push(`${href} scrolled the document to ${state.pageScrollY} on load`);
  }
}

for (const href of chapters) {
  const response = await page.goto(BASE + href, { waitUntil: "networkidle" });
  if (!response || !response.ok()) {
    failures.push(`${href} -> HTTP ${response?.status() ?? "no response"}`);
    continue;
  }
  await checkHead(href);
  await checkSidebarSync(href);
  compileOnly += await page.locator(".pg-static").count();

  pagers.set(
    href,
    await page.evaluate(() => ({
      prev: document.querySelector(".pager-prev")?.getAttribute("href") ?? null,
      next: document.querySelector(".pager-next")?.getAttribute("href") ?? null,
    })),
  );

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
for (const href of [`${PREFIX}/`, `${PREFIX}/paths/`, `${PREFIX}/privacy/`]) {
  const res = await page.goto(BASE + href, { waitUntil: "domcontentloaded" });
  if (!res?.ok()) {
    failures.push(`${href} -> HTTP ${res?.status() ?? "no response"}`);
    continue;
  }
  await checkHead(href);

  // These three are the only pages whose links are not also a chapter's links,
  // and the reading paths are entirely links, so collect them here too.
  for (const link of await page.$$eval("main a[href^='/']", (as) =>
    as.map((a) => a.getAttribute("href")),
  )) {
    internalLinks.add(link);
  }
}

/**
 * The pager and the sidebar are generated from one ordering, and this is what
 * proves they stayed that way: every page carries a link, each "next" is
 * answered by the matching "previous", and following "next" from the first
 * page reaches every page the sidebar lists. A pager that skipped a chapter,
 * or led into a loop, would still look perfectly reasonable on any single page.
 */
let ends = 0;
for (const [href, pager] of pagers) {
  if (!pager.prev) ends++;
  if (!pager.next) ends++;
  if (!pager.prev && !pager.next) failures.push(`${href} has no previous or next link`);
  if (pager.next && pagers.has(pager.next) && pagers.get(pager.next).prev !== href) {
    failures.push(
      `${href} points next at ${pager.next}, which points back at ` +
        `${pagers.get(pager.next).prev ?? "nothing"}`,
    );
  }
}
if (ends !== 2) {
  failures.push(`${ends} pages are missing a previous or next link, want exactly 2 (the ends)`);
}

let walked = 0;
const first = [...pagers].find(([, pager]) => !pager.prev)?.[0];
for (let at = first; at && walked <= pagers.size; walked++) {
  at = pagers.get(at)?.next;
}
if (walked !== pagers.size) {
  failures.push(`walking "next" from the first page reached ${walked} of ${pagers.size} pages`);
}

/**
 * WCAG AA contrast, measured on the rendered page in both themes.
 *
 * Reading computed styles rather than the stylesheet is the point: it resolves
 * `light-dark()`, composites the semi-transparent `color-mix` backgrounds
 * against whatever is actually behind them, and picks up Shiki's per-token
 * custom properties, none of which can be read off the source. A palette edit
 * that drops a colour below AA is invisible on the page to anyone who is not
 * already struggling to read it, so nothing else here would catch it.
 */
const THEME_PAGES = [
  `${PREFIX}/`,
  `${PREFIX}/language-basics/optionals/`,
  `${PREFIX}/networking/`,
];

let contrastChecks = 0;
for (const theme of ["light", "dark"]) {
  for (const href of THEME_PAGES) {
    await page.goto(BASE + href, { waitUntil: "networkidle" });
    await page.evaluate((t) => {
      document.documentElement.dataset.theme = t;
    }, theme);

    const results = await page.evaluate(() => {
      const srgb = (c) => (c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4);
      const parse = (s) => (s.match(/[\d.]+/g) ?? []).map(Number);
      const lum = ([r, g, b]) =>
        0.2126 * srgb(r / 255) + 0.7152 * srgb(g / 255) + 0.0722 * srgb(b / 255);
      const over = (fg, bg) => {
        const a = fg[3] ?? 1;
        return [0, 1, 2].map((i) => fg[i] * a + bg[i] * (1 - a));
      };

      // Walk up compositing every translucent layer until something opaque.
      const backdrop = (el) => {
        const layers = [];
        for (let n = el; n; n = n.parentElement) {
          const c = parse(getComputedStyle(n).backgroundColor);
          if (c.length && (c[3] ?? 1) > 0) {
            layers.push(c);
            if ((c[3] ?? 1) === 1) break;
          }
        }
        layers.push([255, 255, 255]);
        return layers.reduceRight((acc, c) => over(c, acc));
      };

      const out = [];
      const seen = new Set();
      const selectors = [
        "main p",
        "main li",
        "main a",
        ".section-index span",
        ".sidebar a",
        ".nav-track",
        ".status-sub",
        ".pg-status",
        ".pg-note",
        ".pg-run",
        ".unofficial",
        ".theme-toggle",
        ".astro-code span",
      ];

      for (const sel of selectors) {
        let n = 0;
        for (const el of document.querySelectorAll(sel)) {
          if (n >= 12) break;
          const text = (el.textContent ?? "").trim();
          if (!text) continue;
          const cs = getComputedStyle(el);
          if (cs.visibility === "hidden" || cs.display === "none") continue;
          if (!el.getClientRects().length) continue;

          const fg = parse(cs.color);
          if (!fg.length) continue;
          const composed = over(fg, backdrop(el));
          const [hi, lo] = [lum(composed), lum(backdrop(el))].sort((a, b) => b - a);
          const ratio = (hi + 0.05) / (lo + 0.05);

          // WCAG large text: 24px, or 18.66px at 700+.
          const size = parseFloat(cs.fontSize);
          const weight = parseInt(cs.fontWeight, 10) || 400;
          const large = size >= 24 || (size >= 18.66 && weight >= 700);
          const need = large ? 3 : 4.5;

          const key = `${sel}|${cs.color}|${ratio.toFixed(2)}`;
          if (seen.has(key)) continue;
          seen.add(key);
          n++;
          out.push({ sel, ratio, need, color: cs.color, sample: text.slice(0, 28) });
        }
      }
      return out;
    });

    for (const r of results) {
      contrastChecks++;
      if (r.ratio < r.need) {
        failures.push(
          `${theme} ${href} "${r.sel}" ${r.ratio.toFixed(2)}:1 needs ${r.need}:1 ` +
            `(${r.color}, "${r.sample}")`,
        );
      }
    }
  }
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
    `compile-only: ${compileOnly}  pager chain: ${walked}  contrast: ${contrastChecks}  ` +
    `links: ${internalLinks.size}  ` +
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
