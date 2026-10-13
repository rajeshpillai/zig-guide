// Check the paint program's browser build before the site ships it.
//
//   check-paint-wasm.mjs <paint.wasm>
//
// The wasm draws the engine's demo picture and compares its hash with the one
// the native tests pinned (`examples/paint/src/engine/demo.zig`). A match means
// this build and the native build turn the same strokes into the same pixels,
// so the page runs the engine the tests ran. It needs no imports: the engine
// is `wasm32-freestanding` and reads nothing from its host.
//
// Silent on success, like run-wasi.mjs, because the build runner reports any
// stderr from a passing step as a failure.
import { readFile } from "node:fs/promises";

const [path] = process.argv.slice(2);
if (!path) {
  console.error("usage: check-paint-wasm.mjs <paint.wasm>");
  process.exit(2);
}

const { instance } = await WebAssembly.instantiate(await readFile(path), {});
const e = instance.exports;

const problems = [];
if (!e.paint_self_test()) problems.push("the demo picture's hash differs from the one the native tests pinned");
if (!e.paint_init(640, 400)) problems.push("paint_init(640, 400) failed");
else {
  // A fresh document must render as plain white paper.
  e.paint_render();
  const pixels = new Uint8Array(e.memory.buffer, e.paint_display(), 640 * 400 * 4);
  if (!pixels.every((v) => v === 255)) problems.push("a new document is not white");
}

if (problems.length > 0) {
  for (const p of problems) console.error(`paint.wasm: ${p}`);
  process.exit(1);
}
