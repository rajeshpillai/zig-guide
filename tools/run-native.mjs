// Execute a host-native snippet binary, mirroring run-wasi.mjs for the
// snippets that cannot target wasm32-wasi (threads, sockets). Used by
// `zig build verify`.
//
//   run-native.mjs <binary> [expected-stdout.txt]
//
// When an expected-stdout file is given, stdout is compared exactly; a
// mismatch exits non-zero so CI fails on drifted documentation.
//
// Output discipline matches run-wasi.mjs: silent on success, everything on
// failure, because the build runner surfaces any stderr as a failure banner.
import { spawnSync } from "node:child_process";
import { readFile } from "node:fs/promises";

const [binaryPath, expectedPath] = process.argv.slice(2);
if (!binaryPath) {
  console.error("usage: run-native.mjs <binary> [expected-stdout.txt]");
  process.exit(2);
}

// A native snippet that hangs would otherwise stall the whole build until the
// CI job's own limit killed it, with no indication of which snippet did it.
const TIMEOUT_MS = 60_000;
const result = spawnSync(binaryPath, [], {
  encoding: "utf8",
  timeout: TIMEOUT_MS,
});
const timedOut = result.error?.code === "ETIMEDOUT";

const stdout = result.stdout ?? "";
const stderr = result.stderr ?? "";
const exitCode = result.status ?? 134;

let mismatch = null;
if (expectedPath) {
  const expected = await readFile(expectedPath, "utf8");
  if (stdout !== expected) {
    mismatch =
      `stdout mismatch for ${binaryPath}\n` +
      `--- expected ---\n${expected}` +
      `--- actual ---\n${stdout}` +
      `----------------`;
  }
}

const failed = exitCode !== 0 || mismatch !== null;
if (failed) {
  if (stdout) process.stderr.write(stdout);
  if (stderr) process.stderr.write(stderr);
  if (timedOut) {
    // Worth naming as a hang rather than reporting the raw ETIMEDOUT. Every
    // snippet here runs in milliseconds, so reaching this limit means the
    // program stopped making progress, not that it was slow, and the two want
    // very different things looked at. `cancellation` reached it by starting a
    // Group with `async` rather than `concurrent`, which let a task that only
    // ends when cancelled run on the thread that was about to cancel it.
    process.stderr.write(
      `${binaryPath} made no progress for ${TIMEOUT_MS / 1000}s and was killed.\n` +
        `Native snippets here finish in milliseconds, so this is a hang rather ` +
        `than slowness: look for a task that never returns, or one awaited by ` +
        `the thread that was going to end it.\n`,
    );
  } else if (result.error) {
    process.stderr.write(`spawn failed: ${result.error.message}\n`);
  }
  if (mismatch) process.stderr.write(mismatch + "\n");
}

process.exitCode = failed ? (exitCode === 0 ? 1 : exitCode) : 0;
