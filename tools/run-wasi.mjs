// Execute a wasm32-wasi module under Node's WASI, mirroring what the browser
// playground does with a browser WASI shim. Used by `zig build verify`.
//
//   run-wasi.mjs <module.wasm> [expected-stdout.txt]
//   run-wasi.mjs --expect-failure <module.wasm> <expected-error.txt>
//
// When an expected-stdout file is given, stdout is compared exactly; a mismatch
// exits non-zero so CI fails on drifted documentation.
//
// `--expect-failure` inverts the contract for the snippets whose failure is the
// lesson: the module must exit non-zero AND its stderr must contain the text in
// the given file, and this exits 0 when both hold. A snippet that stops failing,
// or fails with a different message than the chapter quotes, turns the build
// red. Without this a demonstration panic could only be described in prose,
// which is the one thing this repository does not allow a snippet to be.
//
// Output discipline: silent on success, everything on failure. `zig test`
// writes its report to stderr even when all tests pass, and the build runner
// surfaces any stderr from a step as an alarming "failed command:" line — so a
// green run must produce no output at all.
import { WASI } from "node:wasi";
import { readFile, open, unlink } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

const argv = process.argv.slice(2);
const expectFailure = argv[0] === "--expect-failure";
const [modulePath, expectedPath] = expectFailure ? argv.slice(1) : argv;
if (!modulePath || (expectFailure && !expectedPath)) {
  console.error(
    "usage: run-wasi.mjs <module.wasm> [expected-stdout.txt]\n" +
      "       run-wasi.mjs --expect-failure <module.wasm> <expected-error.txt>",
  );
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

if (expectFailure) {
  // The trap message is appended because a Zig panic reaches stderr through
  // the module's own writer, while the trap that follows it comes from the
  // engine. Reading only one of the two would miss half the demonstrations.
  const want = (await readFile(expectedPath, "utf8")).trim();
  const got = `${stderr}${trap ? `trapped: ${trap}\n` : ""}`;
  const problems = [];
  if (exitCode === 0) problems.push("expected a failure, but the module exited 0");
  if (!got.includes(want)) problems.push(`stderr does not contain: ${want}`);

  if (problems.length > 0) {
    for (const p of problems) process.stderr.write(`${p}\n`);
    process.stderr.write(`--- stdout ---\n${stdout}--- stderr ---\n${got}`);
    process.exit(1);
  }
  process.exit(0);
}

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
