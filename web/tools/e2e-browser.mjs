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
import { legacyRedirects } from "../legacy-urls.mjs";

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
// Every sidebar link is a chapter and gets walked as one: it must carry a
// pager, and following `next` from the first must reach all of them. The one
// exception is marked `nav-extra` (References), which is a view of the guide
// rather than a stop in it, like `/paths/`. It is checked below with the other
// non-chapter pages instead.
const chapters = await page.$$eval(".sidebar a:not(.nav-extra)", (as) =>
  as.map((a) => a.getAttribute("href")),
);
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
let expectedFailures = 0;
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
    const output = (await block.locator(".pg-output").textContent()).trim();

    // A `//! fails` snippet is on the page because it stops. Asserting exit 0
    // for it would be asserting that the demonstration no longer demonstrates
    // anything, and CI already pins the exact message it must stop with.
    if ((await block.getAttribute("data-expect-fail")) === "true") {
      expectedFailures++;
      if (status.startsWith("exit 0")) {
        failures.push(`${href} [${name}] was supposed to fail and exited 0\n${output}`);
      }
      // A trap with nothing written is not a demonstration. The reader has to
      // see why it stopped, and CI pins the wording separately.
      if (output.length === 0) {
        failures.push(`${href} [${name}] failed without printing anything`);
      }
    } else if (!status.startsWith("exit 0")) {
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
  `${PREFIX}/references/`,
  `${PREFIX}/whats-new/`,
  `${PREFIX}/about/`,
  `${PREFIX}/verification/`,
  `${PREFIX}/contact/`,
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
 * The Edit button, which nothing above touches: the loop over every playground
 * presses Run on unedited source, so the entire editing path could break and
 * this gate would stay green. It renders correctly and only fails once a
 * reader types, which is the worst kind of regression to ship.
 *
 * Deliberately written to pass in both worlds. `zig.wasm` cannot currently be
 * built for `wasm32-wasi`, so `data-can-compile` is false everywhere today and
 * the contract is "say so plainly and offer a way out". If the compiler ever
 * lands, the flag flips and the same check asserts that an edit actually
 * compiles and runs. Neither branch is allowed to silently do nothing.
 *
 * One page is enough. This is the mechanism, not the content, and loading
 * CodeMirror on all 133 playgrounds would cost minutes to learn nothing.
 */
const EDIT_PAGE = `${PREFIX}/learn/getting-started/hello-world/`;
let editPath = "not run";
{
  await page.goto(BASE + EDIT_PAGE, { waitUntil: "networkidle" });
  const block = page.locator("zig-playground").first();
  const canCompile = (await block.getAttribute("data-can-compile")) === "true";

  await block.locator("button.pg-edit").click();
  await page.waitForFunction(() => document.querySelector(".cm-content") !== null, null, {
    timeout: 30000,
  });

  // Entering the editor has to state what Run will do, before anything is
  // typed. Promising a recompile that cannot happen is the bug this replaced.
  const opened = (await block.locator(".pg-status").textContent()).trim();
  const promises = /Run will recompile/.test(opened);
  if (promises !== canCompile) {
    failures.push(
      `${EDIT_PAGE} editor status ${JSON.stringify(opened)} does not match ` +
        `data-can-compile=${canCompile}`,
    );
  }

  await block.locator(".cm-content").click();
  await page.keyboard.type("// edited by the gate\n");
  await block.locator("button.pg-run").click();
  await page.waitForFunction(
    () =>
      !document
        .querySelector("zig-playground .pg-status")
        .textContent.includes("ing…"),
    null,
    { timeout: 60000 },
  );

  const status = (await block.locator(".pg-status").textContent()).trim();
  const output = (await block.locator(".pg-output").textContent()).trim();

  if (canCompile) {
    if (!status.startsWith("exit 0")) {
      failures.push(`${EDIT_PAGE} edited source did not compile and run: ${status}\n${output}`);
    }
  } else {
    // No stack trace, no HTTP status, and no build script the reader does not
    // have: the message is the only thing they get, so it has to read as an
    // explanation rather than an error.
    if (!/needs a Zig compiler in the browser/.test(output)) {
      failures.push(`${EDIT_PAGE} edited source gave no plain explanation: ${output}`);
    }
    if ((await block.locator(".pg-escape").count()) === 0) {
      failures.push(`${EDIT_PAGE} edited source offered no way to run it elsewhere`);
    }
  }

  // Revert has to restore the CI-verified artifact, not merely the text. This
  // is the path most at risk from any change to how edits are detected.
  await block.locator("button.pg-revert").click();
  await block.locator("button.pg-run").click();
  await page.waitForFunction(
    () =>
      !document
        .querySelector("zig-playground .pg-status")
        .textContent.includes("ing…"),
    null,
    { timeout: 30000 },
  );
  const reverted = (await block.locator(".pg-status").textContent()).trim();
  if (!reverted.startsWith("exit 0")) {
    failures.push(`${EDIT_PAGE} Revert then Run did not run the verified wasm: ${reverted}`);
  }

  editPath = canCompile ? "compiles" : "explains";
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
/**
 * The topbar at every width it changes shape at.
 *
 * This bug has now shipped twice. The badges beside the wordmark cannot shrink
 * and `.brand-wrap` can, so once a badge is revealed below the width it needs,
 * it spills out of the shrunken box and the search box paints over it. The
 * first fix moved one element from 560 to 640px and the row still overlapped
 * at 700. Nothing here would have noticed either time: the pages build, every
 * link resolves, the contrast pass reads colours rather than geometry, and a
 * screenshot at one width looks perfectly reasonable.
 *
 * Each width gets its own page load. Resizing one page and re-measuring is far
 * cheaper and gives different answers: Chromium does not reflow the flex row
 * the way it does on a fresh layout, so a resize sweep reported the wordmark
 * whole at 460 (it is ellipsized) and clipped at 388 (it is not). Both
 * readings were wrong in opposite directions, which is worse than no check.
 *
 * The wordmark rule is the one that matters most and is the easiest to lose:
 * every badge up there is restated in the footer, but the site's own name
 * ellipsized to "Zi..." reads as a broken page.
 */
const HEADER_WIDTHS = [
  320, 360, 390, 430, 470, 480, 570, 580, 690, 700, 860, 1030, 1040, 1130,
  1140, 1280, 1440,
];
/**
 * Every width is measured twice: once as the machine renders it, and once with
 * every string in the row widened by letter-spacing.
 *
 * The first pass alone is not a check, it is a check of one font. `system-ui`
 * is whatever fontconfig hands the browser, and the same wordmark is 136px in
 * Noto Sans and 146px in DejaVu Sans. The widths above were measured on a
 * machine with the first and every one of them had exactly zero slack, so CI,
 * whose system-ui is the second, rendered "Zig Guide Li..." at four of them and
 * the pass here went green on the machine they were taken on. A check that only
 * agrees with the machine it was calibrated on is the failure mode this whole
 * block exists to close.
 *
 * 0.75px per character is the stand-in: it is deterministic, it needs no font
 * to be installed, and across the wordmark it is worth ~12px, more than the
 * 10px between the narrowest and widest system-ui in the wild. It is a proxy
 * for headroom rather than a real font, which is the point. Passing means the
 * row survives a system font wider than the one that rendered it.
 */
const HEADER_SPACINGS = [0, 0.75];
let headerWidths = 0;
for (const spacing of HEADER_SPACINGS) {
  for (const width of HEADER_WIDTHS) {
    const page2 = await browser.newPage({ viewport: { width, height: 800 } });
    if (spacing) {
      await page2.addInitScript((ls) => {
        document.addEventListener("DOMContentLoaded", () => {
          const s = document.createElement("style");
          s.textContent = `.topbar, .topbar * { letter-spacing: ${ls}px !important; }`;
          document.head.appendChild(s);
        });
      }, spacing);
    }
    await page2.goto(`${BASE}${PREFIX}/learn/language-basics/pointers/`, {
      waitUntil: "domcontentloaded",
    });
    const seen = await page2.evaluate(() => {
      const boxes = [...document.querySelectorAll(".topbar > *, .brand-wrap > *")]
        .filter((e) => getComputedStyle(e).display !== "none")
        .filter((e) => !e.classList.contains("brand-wrap"))
        .map((e) => ({ name: (e.className || e.tagName).toString().split(" ")[0], ...e.getBoundingClientRect().toJSON() }))
        .filter((b) => b.width > 0)
        .sort((a, b) => a.left - b.left);

      let collision = null;
      for (let i = 1; i < boxes.length; i++) {
        if (boxes[i].left < boxes[i - 1].right - 0.5) {
          collision = `${boxes[i - 1].name} overlaps ${boxes[i].name}`;
        }
      }

      const brand = document.querySelector(".brand");
      // Own computed display, not visibility: the nav panel holding the
      // fallback copy is closed on a phone, which is not the same as absent.
      const shown = (sel) => {
        const el = document.querySelector(sel);
        return el !== null && getComputedStyle(el).display !== "none";
      };
      const bar = document.querySelector(".topbar");
      const last = boxes[boxes.length - 1];
      return {
        collision,
        truncated: brand.scrollWidth > brand.clientWidth + 1,
        // Where the overflow goes once the wordmark stops absorbing it. The
        // row shrinking the search box is the intended degradation; the row
        // pushing its last control past the viewport is not, and it is
        // invisible in a screenshot because the body clips it.
        spill: Math.round(last.right - bar.getBoundingClientRect().right),
        migrationReachable: shown(".topbar-link") || shown(".nav-aside"),
      };
    });

    headerWidths++;
    const at = `topbar at ${width}px${spacing ? ` (+${spacing}px letter-spacing)` : ""}`;
    if (seen.collision) failures.push(`${at}: ${seen.collision}`);
    // No width exemption. There used to be one below 388px, where the wordmark
    // was said not to fit at all, but 388 was itself a measurement of one font.
    // The brand no longer shrinks at any width, so the rule is simply that the
    // site's name is never rendered as "Zig Guide Li...".
    if (seen.truncated) failures.push(`${at}: the wordmark is ellipsized`);
    if (seen.spill > 1) {
      failures.push(`${at}: the row spills ${seen.spill}px past the viewport`);
    }
    if (!seen.migrationReachable) {
      failures.push(`${at}: "On an older Zig?" is on no surface`);
    }
    await page2.close();
  }
}

const THEME_PAGES = [
  `${PREFIX}/`,
  `${PREFIX}/learn/language-basics/optionals/`,
  `${PREFIX}/learn/networking/`,
  // Carries a compile-only playground, so it is the only one of these that
  // measures `.pg-note` and `.pg-try`. Both sit on small muted text, which is
  // exactly where a palette edit stops being legible first.
  `${PREFIX}/learn/os/signals/`,
];

/*
 * Both axes, every combination. A palette is a block of token overrides and a
 * theme picks a column out of each one, so the two multiply rather than
 * overlap: a pair that clears AA in Zig dark says nothing about the same pair
 * in Nord dark, where a lighter accent sits on a lighter surface.
 *
 * One page load serves all six, and that is not a shortcut. Nothing here
 * measures loading; it reads computed styles, and both attributes are pure CSS
 * switches that the browser has fully resolved by the time the next evaluate
 * runs. Reloading per combination would have turned 8 loads into 24 to learn
 * the same thing.
 */
const PALETTES = ["paper", "zig", "nord"];

let contrastChecks = 0;
for (const href of THEME_PAGES) {
  await page.goto(BASE + href, { waitUntil: "networkidle" });
  for (const palette of PALETTES) {
  for (const theme of ["light", "dark"]) {
    await page.evaluate(({ t, p }) => {
      document.documentElement.dataset.theme = t;
      // "paper" is the absence of the attribute, exactly as the picker writes
      // it, so this measures the default state rather than a value no block
      // in the stylesheet defines.
      if (p === "paper") delete document.documentElement.dataset.palette;
      else document.documentElement.dataset.palette = p;
    }, { t: theme, p: palette });

    const results = await page.evaluate(() => {
      const srgb = (c) => (c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4);
      const parse = (s) => {
        const n = (s.match(/[\d.]+/g) ?? []).map(Number);
        if (!s.startsWith("color(")) return n;
        // Chromium serialises the result of `color-mix()` as
        // `color(srgb r g b / a)`, and those channels run 0 to 1 rather than
        // 0 to 255. Read as though they were 0 to 255 every translucent accent
        // fill composited as near-black, which moved the measured ratio in
        // opposite directions in the two themes: too harsh on light, where the
        // text is dark, and too generous on dark, where it is not. Any colour
        // space but srgb is refused rather than guessed at, because scaling a
        // display-p3 channel into sRGB is wrong without saying so.
        if (!s.startsWith("color(srgb")) throw new Error(`unhandled colour space: ${s}`);
        return [n[0] * 255, n[1] * 255, n[2] * 255, ...n.slice(3)];
      };
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
          `${palette} ${theme} ${href} "${r.sel}" ${r.ratio.toFixed(2)}:1 ` +
            `needs ${r.need}:1 (${r.color}, "${r.sample}")`,
        );
      }
    }
  }
  }
}

/*
 * The palette picker, and with it the progressive-enhancement contract the
 * search box and the theme toggle keep.
 *
 * Two failures live here and neither one is visible in a screenshot. The first
 * is the picker not working: a row of three buttons that set nothing looks
 * exactly like a row of three buttons that do. The second is the opposite and
 * is the reason `[hidden]` carries an `!important` in the stylesheet: `[hidden]`
 * is a user-agent rule, so any author `display` on the same element beats it,
 * and every control revealed by script sets one. Without that rule the JS-off
 * page renders all of them, inert, which is precisely what shipping them
 * hidden was meant to prevent.
 */
let pickerChecks = 0;
{
  const href = `${PREFIX}/learn/language-basics/optionals/`;
  await page.goto(BASE + href, { waitUntil: "networkidle" });

  const wired = await page.evaluate(() => {
    const row = document.querySelector(".palette-pick");
    const buttons = [...document.querySelectorAll("[data-palette-set]")];
    return {
      revealed: row !== null && !row.hidden,
      count: buttons.length,
      pressed: buttons.filter((b) => b.getAttribute("aria-pressed") === "true").length,
      // Nothing chosen yet, so the default is the attribute's absence.
      attr: document.documentElement.dataset.palette ?? null,
    };
  });
  pickerChecks++;
  if (!wired.revealed) failures.push("palette picker: never revealed by its script");
  if (wired.count !== 3) failures.push(`palette picker: ${wired.count} swatches, expected 3`);
  if (wired.pressed !== 1) failures.push(`palette picker: ${wired.pressed} pressed, expected 1`);
  if (wired.attr !== null) failures.push(`palette picker: default wrote data-palette="${wired.attr}"`);

  for (const id of ["nord", "zig", "paper"]) {
    await page.click(`[data-palette-set="${id}"]`);
    const after = await page.evaluate((chosen) => {
      const button = document.querySelector(`[data-palette-set="${chosen}"]`);
      return {
        attr: document.documentElement.dataset.palette ?? null,
        pressed: button.getAttribute("aria-pressed") === "true",
        others: [...document.querySelectorAll("[data-palette-set]")]
          .filter((b) => b.getAttribute("aria-pressed") === "true").length,
        stored: localStorage.getItem("palette"),
      };
    }, id);

    // Paper is the default and so is written as no attribute at all, which is
    // what makes it survive a later change to the base tokens.
    const want = id === "paper" ? null : id;
    pickerChecks++;
    if (after.attr !== want) {
      failures.push(`palette picker: clicking ${id} left data-palette=${after.attr}`);
    }
    if (!after.pressed || after.others !== 1) {
      failures.push(`palette picker: clicking ${id} left ${after.others} swatch(es) pressed`);
    }
    if (after.stored !== id) {
      failures.push(`palette picker: clicking ${id} stored "${after.stored}"`);
    }
  }

  // The choice has to outlive the page, and it has to be applied before the
  // stylesheet resolves a single `light-dark()` or every navigation flashes.
  await page.evaluate(() => localStorage.setItem("palette", "nord"));
  await page.goto(BASE + `${PREFIX}/learn/networking/`, { waitUntil: "domcontentloaded" });
  const restored = await page.evaluate(() => document.documentElement.dataset.palette ?? null);
  pickerChecks++;
  if (restored !== "nord") {
    failures.push(`palette picker: choice did not survive navigation (${restored})`);
  }
  await page.evaluate(() => localStorage.removeItem("palette"));

  // A value no block in the stylesheet defines must not reach <html>, or the
  // reader is left on a palette made of whatever the base tokens happen to be.
  await page.evaluate(() => localStorage.setItem("palette", "solarized"));
  await page.goto(BASE + href, { waitUntil: "domcontentloaded" });
  const junk = await page.evaluate(() => document.documentElement.dataset.palette ?? null);
  pickerChecks++;
  if (junk !== null) failures.push(`palette picker: accepted unknown palette "${junk}"`);
  await page.evaluate(() => localStorage.removeItem("palette"));
}

/* Every script-revealed control, with scripting off. */
let jsOffChecks = 0;
{
  const context = await browser.newContext({ javaScriptEnabled: false });
  const bare = await context.newPage();
  await bare.goto(BASE + `${PREFIX}/learn/language-basics/optionals/`, {
    waitUntil: "domcontentloaded",
  });
  const visible = await bare.$$eval(
    ".palette-pick, .theme-toggle, [hidden]",
    (nodes) =>
      nodes
        .filter((n) => getComputedStyle(n).display !== "none")
        .map((n) => (n.className || n.tagName).toString().split(" ")[0]),
  );
  jsOffChecks++;
  if (visible.length) {
    failures.push(`JS off: inert control(s) rendered anyway: ${visible.join(", ")}`);
  }
  // The floor the whole site stands on: a snippet is still readable code.
  const readable = await bare.$$eval(".astro-code", (n) => n.length);
  jsOffChecks++;
  if (!readable) failures.push("JS off: no snippet rendered as a code block");
  await context.close();
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
 * Every address the guide has ever had still lands on the page that replaced
 * it. Nothing on the site links to any of them, and none of them appears in
 * the sitemap, so this is the only thing that will ever look: the failure mode
 * is a chapter moving, its redirect quietly pointing at a 404, and the only
 * report of it arriving months later in Search Console.
 *
 * Checked as documents rather than by following them. A zero-delay meta
 * refresh is what a crawler reads, and asserting the URL it names is what
 * proves the base path made it into the destination — a redirect built without
 * the prefix would still load fine in a browser here and 404 in production.
 */
const legacy = Object.entries(legacyRedirects(`${PREFIX}/`));
let redirectsChecked = 0;
const destinations = new Set();
for (const [from, to] of legacy) {
  const res = await page.request.get(`${BASE}${PREFIX}${from}/`);
  if (!res.ok()) {
    failures.push(`legacy URL ${PREFIX}${from}/ -> HTTP ${res.status()}, want a redirect`);
    continue;
  }
  const html = await res.text();
  const refresh = html.match(/http-equiv="refresh" content="\d+;url=([^"]+)"/)?.[1];
  if (refresh !== to) {
    failures.push(`legacy URL ${PREFIX}${from}/ redirects to ${refresh ?? "nothing"}, want ${to}`);
    continue;
  }
  if (!/name="robots" content="noindex"/.test(html)) {
    failures.push(`legacy URL ${PREFIX}${from}/ is a redirect Google would index`);
  }
  destinations.add(to);
  redirectsChecked++;
}
for (const to of destinations) {
  const res = await page.request.get(BASE + to);
  if (!res.ok()) failures.push(`legacy redirect destination ${to} -> HTTP ${res.status()}`);
}

// The page the host serves for everything else. GitHub Pages wants it at this
// exact path, and Astro only puts it there because of the filename.
const notFound = await page.request.get(`${BASE}${PREFIX}/404.html`);
if (!notFound.ok()) {
  failures.push(`404.html -> HTTP ${notFound.status()}; GitHub Pages will serve its own`);
} else {
  const html = await notFound.text();
  if (!/name="robots" content="noindex/.test(html)) failures.push("404.html is indexable");
  if (!html.includes(`href="${PREFIX}/learn/"`)) {
    failures.push("404.html does not link to the guide index, which is the way back in");
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
    `compile-only: ${compileOnly}  expected failures: ${expectedFailures}  ` +
    `edit path: ${editPath}  ` +
    `pager chain: ${walked}  contrast: ${contrastChecks}  ` +
    `picker: ${pickerChecks}  js-off: ${jsOffChecks}  ` +
    `header widths: ${headerWidths}  ` +
    `links: ${internalLinks.size}  ` +
    `broken: ${brokenLinks}  sitemap: ${sitemapCount}  ` +
    `legacy redirects: ${redirectsChecked}  ` +
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
