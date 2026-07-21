// Execute a wasm32-wasi module under Node's WASI, mirroring what the browser
// playground does with a browser WASI shim. Used by `zig build verify`.
//
//   run-wasi.mjs <module.wasm> [expected-stdout.txt]
//
// When an expected-stdout file is given, stdout is compared exactly; a mismatch
// exits non-zero so CI fails on drifted documentation.
//
// Output discipline: silent on success, everything on failure. `zig test`
// writes its report to stderr even when all tests pass, and the build runner
// surfaces any stderr from a step as an alarming "failed command:" line — so a
// green run must produce no output at all.
import { WASI } from "node:wasi";
import { readFile, open, unlink } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

const [modulePath, expectedPath] = process.argv.slice(2);
if (!modulePath) {
  console.error("usage: run-wasi.mjs <module.wasm> [expected-stdout.txt]");
  process.exit(2);
}

// WASI needs real fds, so route both streams through temp files.
const stem = join(tmpdir(), `zig-guide-${process.pid}`);
const outPath = `${stem}.out`;
const errPath = `${stem}.err`;
const outHandle = await open(outPath, "w+");
const errHandle = await open(errPath, "w+");

let exitCode = 0;
let trap = null;

try {
  const wasi = new WASI({
    version: "preview1",
    args: [modulePath],
    env: {},
    returnOnExit: true,
    stdout: outHandle.fd,
    stderr: errHandle.fd,
  });

  const module = await WebAssembly.compile(await readFile(modulePath));
  const instance = await WebAssembly.instantiate(module, wasi.getImportObject());
  exitCode = wasi.start(instance);
} catch (err) {
  trap = err instanceof Error ? err.message : String(err);
  exitCode = 134;
}

const stdout = await readFile(outPath, "utf8");
const stderr = await readFile(errPath, "utf8");
await Promise.all([outHandle.close(), errHandle.close()]);
await Promise.all([unlink(outPath), unlink(errPath)]).catch(() => {});

let mismatch = null;
if (expectedPath) {
  const expected = await readFile(expectedPath, "utf8");
  if (stdout !== expected) {
    mismatch =
      `stdout mismatch for ${modulePath}\n` +
      `--- expected ---\n${expected}` +
      `--- actual ---\n${stdout}` +
      `----------------`;
  }
}

const failed = exitCode !== 0 || mismatch !== null;
if (failed) {
  if (stdout) process.stderr.write(stdout);
  if (stderr) process.stderr.write(stderr);
  if (trap) process.stderr.write(`trapped: ${trap}\n`);
  if (mismatch) process.stderr.write(mismatch + "\n");
}

process.exitCode = failed ? (exitCode === 0 ? 1 : exitCode) : 0;
