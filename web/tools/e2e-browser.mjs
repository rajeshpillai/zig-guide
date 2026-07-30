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
  ".md": "text/markdown",
  ".txt": "text/plain",
  ".xml": "application/xml",
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
/** Chapter URL to the `.md` twin its head advertises. */
const markdownLinks = new Map();
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
    markdown: document.querySelector('link[rel="alternate"][type="text/markdown"]')?.getAttribute("href") ?? "",
    feed: document.querySelector('link[rel="alternate"][type="application/rss+xml"]')?.getAttribute("href") ?? "",
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
  // Set from a top-level graph node, not from the text of the block. A section
  // index is a CollectionPage that lists a TechArticle per chapter under
  // `hasPart`, so any test that just looks for the word calls all 13 indexes
  // chapters and then demands a `.md` twin none of them has.
  let isChapter = false;
  for (const block of head.jsonLd) {
    try {
      const parsed = JSON.parse(block);
      const nodes = parsed["@graph"] ?? [];
      const types = nodes.map((n) => n["@type"]);
      if (!types.includes("BreadcrumbList")) {
        failures.push(`${href} JSON-LD has no BreadcrumbList`);
      }

      // Dates come from `git log`. On a shallow clone git-dates emits none at
      // all rather than 145 identical ones, so an article with no dateModified
      // is the visible symptom of a checkout without fetch-depth: 0 — which is
      // otherwise a silent, total loss of the freshness signal.
      const article = nodes.find((n) => n["@type"] === "TechArticle");
      if (article) {
        isChapter = true;
        for (const field of ["datePublished", "dateModified"]) {
          if (!article[field]) {
            failures.push(
              `${href} TechArticle has no ${field} ` +
                `(git-dates found nothing: shallow clone, or no .git?)`,
            );
          } else if (Number.isNaN(Date.parse(article[field]))) {
            failures.push(`${href} TechArticle ${field} is not a date: ${article[field]}`);
          }
        }
      }
    } catch (e) {
      failures.push(`${href} JSON-LD is not valid JSON: ${e.message}`);
    }
  }

  // The plain-Markdown twin every chapter advertises. Checked here rather than
  // in the link sweep below, which only collects hrefs from `main`.
  if (head.markdown) {
    markdownLinks.set(href, head.markdown);
  } else if (isChapter) {
    failures.push(`${href} is a chapter but advertises no text/markdown alternate`);
  }
  if (!head.feed) failures.push(`${href} has no RSS alternate link`);

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
// `/learn/` is one of them: it is the chapter list rather than a chapter, so
// like `/paths/` it is a view of the guide and not a stop in the pager.
for (const href of [
  `${PREFIX}/`,
  `${PREFIX}/learn/`,
  `${PREFIX}/paths/`,
  `${PREFIX}/whats-new/`,
  `${PREFIX}/privacy/`,
]) {
  const res = await page.goto(BASE + href, { waitUntil: "domcontentloaded" });
  if (!res?.ok()) {
    failures.push(`${href} -> HTTP ${res?.status() ?? "no response"}`);
    continue;
  }
  await checkHead(href);

  // These are the only pages whose links are not also a chapter's links, and
  // two of them (reading paths, what's new) are almost entirely links, so
  // collect them here too.
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
  `${PREFIX}/learn/language-basics/optionals/`,
  `${PREFIX}/learn/networking/`,
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
  const xml = await sitemapRes.text();
  const locs = [...xml.matchAll(/<loc>([^<]+)<\/loc>/g)].map((m) => m[1]);
  sitemapCount = locs.length;
  const listed = new Set(locs.map((loc) => new URL(loc).pathname));

  for (const path of visited) {
    if (!listed.has(path)) failures.push(`${path} is not listed in sitemap.xml`);
  }
  for (const path of listed) {
    const res = await page.request.get(BASE + path);
    if (!res.ok()) failures.push(`sitemap entry ${path} -> HTTP ${res.status()}`);
  }

  // Every entry needs a real `lastmod`, and none may carry `changefreq` or
  // `priority`. Google ignores the latter two and discounts a file that abuses
  // them, so re-adding them would quietly devalue the one hint it does read.
  const entries = [...xml.matchAll(/<url>([\s\S]*?)<\/url>/g)].map((m) => m[1]);
  const undated = entries.filter((e) => !/<lastmod>/.test(e)).length;
  if (undated > 0) {
    failures.push(
      `${undated} of ${entries.length} sitemap entries have no <lastmod> ` +
        `(git-dates found nothing: shallow clone, or no .git?)`,
    );
  }
  for (const [, date] of xml.matchAll(/<lastmod>([^<]+)<\/lastmod>/g)) {
    if (Number.isNaN(Date.parse(date))) failures.push(`sitemap lastmod is not a date: ${date}`);
  }
  if (/<changefreq>|<priority>/.test(xml)) {
    failures.push("sitemap.xml emits <changefreq> or <priority>; Google ignores both");
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
  // The AI crawlers are named on purpose, and a `Disallow` under any of them
  // would be a policy reversal rather than a typo. Assert the intent both ways.
  for (const agent of ["GPTBot", "OAI-SearchBot", "ClaudeBot", "PerplexityBot", "Google-Extended"]) {
    const block = robots.match(new RegExp(`^User-agent: ${agent}$\\n((?:(?!User-agent:)[^\\n]*\\n)*)`, "m"));
    if (!block) failures.push(`robots.txt does not name ${agent}`);
    else if (/^Disallow:\s*\//m.test(block[1])) failures.push(`robots.txt disallows ${agent}`);
  }
}

/**
 * The machine-readable surfaces: `llms.txt`, `llms-full.txt`, the `.md` twin of
 * every chapter, the feed, and the IndexNow key.
 *
 * None of these is reachable by clicking, none is visible on any page, and all
 * of them are generated from the same collection the site is. That combination
 * is exactly how one of them ends up empty, or listing a URL that 404s, for
 * months without anyone noticing.
 */
const machine = { llms: 0, mdPages: 0, feedItems: 0 };

const llmsRes = await page.request.get(`${BASE}${PREFIX}/llms.txt`);
if (!llmsRes.ok()) {
  failures.push(`llms.txt -> HTTP ${llmsRes.status()}`);
} else {
  const llms = await llmsRes.text();
  // The convention is an H1, then a blockquote summary, then link sections.
  if (!llms.startsWith("# ")) failures.push("llms.txt does not start with an H1");
  if (!/^> /m.test(llms)) failures.push("llms.txt has no blockquote summary");

  const links = [...llms.matchAll(/\]\((https?:\/\/[^)]+)\)/g)].map((m) => m[1]);
  machine.llms = links.length;

  // Every chapter, by name rather than by count. The index is generated from
  // `navTracks()` and a track or section that came back empty would still be
  // valid Markdown and still have plenty of links in it; what would be missing
  // is a specific set of chapters, so that is what to say. Compared against the
  // `.md` twins the pages themselves advertise, not against the sidebar, which
  // also lists the section indexes and those have no Markdown form.
  const listed = new Set(links.map((l) => new URL(l).pathname));
  const missing = [...markdownLinks.values()].filter(
    (md) => !listed.has(new URL(BASE + md).pathname),
  );
  if (missing.length > 0) {
    failures.push(
      `llms.txt omits ${missing.length} of ${markdownLinks.size} chapters: ` +
        `${missing.slice(0, 5).join(", ")}${missing.length > 5 ? ", ..." : ""}`,
    );
  }
  for (const link of links) {
    const res = await page.request.get(BASE + new URL(link).pathname);
    if (!res.ok()) failures.push(`llms.txt link ${new URL(link).pathname} -> HTTP ${res.status()}`);
  }
}

const fullRes = await page.request.get(`${BASE}${PREFIX}/llms-full.txt`);
if (!fullRes.ok()) {
  failures.push(`llms-full.txt -> HTTP ${fullRes.status()}`);
} else {
  const full = await fullRes.text();
  // Every chapter's heading, and the code that is the reason to fetch this at
  // all. A Playground that failed to expand would leave the component tag.
  if (!full.includes("```zig")) failures.push("llms-full.txt contains no zig code blocks");
  if (full.includes("<Playground")) {
    failures.push("llms-full.txt still contains raw <Playground> tags");
  }
  if (/^import\s/m.test(full)) failures.push("llms-full.txt still contains MDX import lines");
  if (full.length < 100_000) {
    failures.push(`llms-full.txt is only ${full.length} bytes; the whole guide should be larger`);
  }
}

for (const [href, md] of markdownLinks) {
  const res = await page.request.get(BASE + md);
  if (!res.ok()) {
    failures.push(`${href} markdown alternate ${md} -> HTTP ${res.status()}`);
    continue;
  }
  const body = await res.text();
  machine.mdPages++;
  if (!body.startsWith("# ")) failures.push(`${md} does not start with an H1`);
  if (body.includes("<Playground")) failures.push(`${md} still contains a raw <Playground> tag`);
  if (/^import\s/m.test(body)) failures.push(`${md} still contains an MDX import line`);
}

const rssRes = await page.request.get(`${BASE}${PREFIX}/rss.xml`);
if (!rssRes.ok()) {
  failures.push(`rss.xml -> HTTP ${rssRes.status()}`);
} else {
  const rss = await rssRes.text();
  const items = [...rss.matchAll(/<item>([\s\S]*?)<\/item>/g)].map((m) => m[1]);
  machine.feedItems = items.length;
  if (items.length === 0) failures.push("rss.xml has no items");

  // The channel's own URLs, which no reader of the site ever clicks. `rel=self`
  // is how an aggregator re-fetches the feed, so one built without the base
  // path points a project site's subscribers at a 404 on the host root, and
  // every page of the site still looks perfect.
  for (const [what, url] of [
    ["atom:link rel=self", rss.match(/<atom:link href="([^"]+)" rel="self"/)?.[1]],
    ["channel link", rss.match(/<channel>[\s\S]*?<link>([^<]+)<\/link>/)?.[1]],
  ]) {
    if (!url) {
      failures.push(`rss.xml has no ${what}`);
      continue;
    }
    const res = await page.request.get(BASE + new URL(url).pathname);
    if (!res.ok()) failures.push(`rss ${what} ${new URL(url).pathname} -> HTTP ${res.status()}`);
  }
  // Every prefix is declared: an undeclared one makes the whole document
  // ill-formed, and most readers drop the feed silently rather than complain.
  for (const [, prefix] of rss.matchAll(/<(\w+):[\w-]+/g)) {
    if (!rss.includes(`xmlns:${prefix}=`)) {
      failures.push(`rss.xml uses the ${prefix}: namespace without declaring it`);
      break;
    }
  }
  for (const item of items) {
    const link = item.match(/<link>([^<]+)<\/link>/)?.[1];
    if (!link) {
      failures.push("rss.xml has an item with no <link>");
      continue;
    }
    const res = await page.request.get(BASE + new URL(link).pathname);
    if (!res.ok()) failures.push(`rss item ${new URL(link).pathname} -> HTTP ${res.status()}`);
  }
}

/**
 * The IndexNow key file must be served at the host root and must contain the
 * key the deploy submits. If the two disagree every submission is rejected and
 * nothing anywhere fails, which is why both are generated from one constant and
 * why that is worth asserting rather than trusting.
 */
const keyMatch = (await readFile(resolve(DIST, "..", "src", "indexnow.ts"), "utf8")).match(
  /INDEXNOW_KEY\s*=\s*"([a-f0-9]+)"/,
);
if (!keyMatch) {
  failures.push("src/indexnow.ts does not define INDEXNOW_KEY as a hex string literal");
} else {
  // Under the prefix, matching the `keyLocation` the submitter sends. A key
  // file authorises the URLs beneath it, and every URL here is beneath this.
  const keyRes = await page.request.get(`${BASE}${PREFIX}/${keyMatch[1]}.txt`);
  if (!keyRes.ok()) {
    failures.push(`IndexNow key file /${keyMatch[1]}.txt -> HTTP ${keyRes.status()}`);
  } else if ((await keyRes.text()).trim() !== keyMatch[1]) {
    failures.push(`IndexNow key file does not contain the key from src/indexnow.ts`);
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
    `llms.txt: ${machine.llms}  .md: ${machine.mdPages}  feed: ${machine.feedItems}  ` +
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
