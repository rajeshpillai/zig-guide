/**
 * Renders the social preview card to `public/og.png`.
 *
 *   node tools/make-og-image.mjs
 *
 * Run by hand, and the result is committed. The card carries no version
 * number and no chapter count on purpose: anything that changes nightly would
 * be stale in the image the day after it was generated, and a preview card is
 * the one surface with no build step watching it.
 *
 * Playwright is already a dependency for the browser gate, so this needs
 * nothing new installed.
 */
import { chromium } from "playwright";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const OUT = resolve(dirname(fileURLToPath(import.meta.url)), "..", "public", "og.png");

// Matches the site's tokens in src/styles/global.css.
const html = `<!doctype html>
<meta charset="utf-8">
<style>
  * { box-sizing: border-box; margin: 0; }
  body {
    width: 1200px; height: 630px;
    background: #0d1117;
    color: #e6edf3;
    font-family: ui-sans-serif, system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
    padding: 84px 96px;
    display: flex; flex-direction: column; justify-content: space-between;
    /* A soft amber wash from the top-left, so the card is not a flat rectangle. */
    background-image: radial-gradient(900px 520px at 8% -10%, rgba(247,164,29,.16), transparent 70%);
  }
  .brand { font-size: 30px; color: #f7a41d; letter-spacing: -.01em; font-weight: 600; }
  h1 { font-size: 88px; line-height: 1.04; letter-spacing: -.03em; font-weight: 800; max-width: 17ch; }
  h1 em { font-style: normal; color: #f7a41d; }
  p { font-size: 30px; line-height: 1.42; color: #8b949e; max-width: 34ch; }
  .foot { display: flex; align-items: center; gap: 20px; font-size: 24px; }
  .badge {
    display: inline-flex; align-items: center; gap: 10px;
    padding: 12px 20px; border-radius: 999px;
    border: 1px solid rgba(63,185,80,.45);
    background: rgba(63,185,80,.12);
    color: #3fb950; font-weight: 600;
  }
  .host { color: #8b949e; font-family: ui-monospace, Menlo, monospace; }
</style>
<div class="brand">⚡ Zig Guide Live</div>
<h1>Learn Zig from code that <em>still compiles</em>.</h1>
<p>A tutorial and cookbook re-verified against Zig master every night. Every snippet runs in your browser.</p>
<div class="foot">
  <span class="badge">✓ compiled and run by CI</span>
  <span class="host">www.ziglang.in</span>
</div>`;

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1200, height: 630 } });
await page.setContent(html, { waitUntil: "load" });
await page.screenshot({ path: OUT });
await browser.close();

console.log(`wrote ${OUT}`);
