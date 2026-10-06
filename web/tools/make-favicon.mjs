/**
 * Renders `public/favicon.svg` to `public/favicon.ico` and
 * `public/apple-touch-icon.png`.
 *
 *   npm run favicon
 *
 * Run by hand, and the results are committed, like `og.png`. The SVG is the
 * source and the icon modern browsers use. The `.ico` exists because browsers,
 * feed readers and crawlers still request `/favicon.ico` without reading any
 * `<link>`, and before it existed every one of those requests got the 404
 * page. The `.ico` holds PNG images, which every browser since IE has read.
 */
import { chromium } from "playwright";
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const PUBLIC = resolve(dirname(fileURLToPath(import.meta.url)), "..", "public");
const svg = readFileSync(resolve(PUBLIC, "favicon.svg"), "utf8");

const browser = await chromium.launch();
const page = await browser.newPage();

async function render(size, { square = false } = {}) {
  await page.setViewportSize({ width: size, height: size });
  // The Apple icon is square: iOS rounds the corners itself, and a rounded
  // source would show the page background in them.
  const body = square ? svg.replace(/rx="\d+"/, 'rx="0"') : svg;
  await page.setContent(
    `<style>*{margin:0}body{background:transparent}svg{display:block;width:${size}px;height:${size}px}</style>${body}`,
  );
  return page.screenshot({ omitBackground: true, type: "png" });
}

const sizes = [16, 32, 48];
const images = [];
for (const size of sizes) images.push(await render(size));
writeFileSync(resolve(PUBLIC, "apple-touch-icon.png"), await render(180, { square: true }));
await browser.close();

// ICONDIR, one ICONDIRENTRY per image, then the PNG bytes.
const header = Buffer.alloc(6 + 16 * images.length);
header.writeUInt16LE(0, 0);
header.writeUInt16LE(1, 2);
header.writeUInt16LE(images.length, 4);
let offset = header.length;
images.forEach((png, i) => {
  const at = 6 + 16 * i;
  header.writeUInt8(sizes[i], at);
  header.writeUInt8(sizes[i], at + 1);
  header.writeUInt8(0, at + 2);
  header.writeUInt8(0, at + 3);
  header.writeUInt16LE(1, at + 4);
  header.writeUInt16LE(32, at + 6);
  header.writeUInt32LE(png.length, at + 8);
  header.writeUInt32LE(offset, at + 12);
  offset += png.length;
});
writeFileSync(resolve(PUBLIC, "favicon.ico"), Buffer.concat([header, ...images]));
console.log(`wrote favicon.ico (${sizes.join(", ")}) and apple-touch-icon.png`);
