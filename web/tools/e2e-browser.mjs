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
    if (PREFIX && path.startsWith(PREFIX)) path = path.slice(PREFIX.length) || "/";
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
let playgrounds = 0;
let compileOnly = 0;

for (const href of chapters) {
  const response = await page.goto(BASE + href, { waitUntil: "networkidle" });
  if (!response || !response.ok()) {
    failures.push(`${href} -> HTTP ${response?.status() ?? "no response"}`);
    continue;
  }
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

let brokenLinks = 0;
for (const href of internalLinks) {
  const res = await page.request.get(BASE + href);
  if (!res.ok()) {
    brokenLinks++;
    failures.push(`broken link ${href} -> HTTP ${res.status()}`);
  }
}

await browser.close();
hosted?.server.close();

console.log(
  `pages: ${chapters.length}  playgrounds: ${playgrounds}  ` +
    `compile-only: ${compileOnly}  links: ${internalLinks.size}  ` +
    `broken: ${brokenLinks}  console errors: ${consoleErrors.size}`,
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
