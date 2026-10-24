// Compile a `//! compile-fails` snippet and require the compiler to refuse it
// with a given message. Used by `zig build verify`.
//
//   expect-compile-error.mjs <zig> <zig-version> <snippet.zig> <expected-error.txt>
//
// Some lessons are a compile error: a `@compileError` with your own message, a
// unit mismatch caught by the type system. Before this, the only place for such
// a message was a fenced block in prose, which nothing checks. Here the snippet
// is compiled for the same wasm32-wasi target as every other snippet, and this
// exits 0 only when the compiler fails AND its output contains each line of the
// expected file, in order. Lines, not one block, because the compiler prints the
// offending source line between an `error:` and its `note:`, and pinning that
// would make a whitespace edit to the snippet fail the gate. A snippet that
// starts to compile, or fails with other wording, turns the build red, on the
// same terms as `//! fails` does for a runtime panic.
//
// `-fno-emit-bin` keeps the full semantic analysis, which is where every
// comptime error comes from, and skips code generation. The version argument is
// not read: it is on the command line so a toolchain bump re-runs this step,
// for the same reason `check-deprecations.mjs` takes it.
//
// Output discipline is the same as `run-wasi.mjs`: silent on success.
import { spawnSync } from "node:child_process";
import { readFile } from "node:fs/promises";

const [zig, , source, expectedPath] = process.argv.slice(2);
if (!zig || !source || !expectedPath) {
  console.error("usage: expect-compile-error.mjs <zig> <zig-version> <snippet.zig> <expected-error.txt>");
  process.exit(2);
}

const result = spawnSync(
  zig,
  ["build-exe", "-target", "wasm32-wasi", "-fno-emit-bin", source],
  { encoding: "utf8" },
);
if (result.error) {
  console.error(`could not start ${zig}: ${result.error.message}`);
  process.exit(1);
}

const want = (await readFile(expectedPath, "utf8"))
  .split("\n")
  .map((line) => line.trim())
  .filter((line) => line !== "");
const got = `${result.stdout}${result.stderr}`;
const problems = [];
if (result.status === 0) problems.push(`expected a compile error, but ${source} compiled`);
if (want.length === 0) problems.push(`${expectedPath} is empty`);
let at = 0;
for (const line of want) {
  const found = got.indexOf(line, at);
  if (found === -1) {
    problems.push(`compiler output does not contain, at this point or later: ${line}`);
    break;
  }
  at = found + line.length;
}

if (problems.length > 0) {
  for (const p of problems) process.stderr.write(`${p}\n`);
  process.stderr.write(`--- compiler output ---\n${got}`);
  process.exit(1);
}
