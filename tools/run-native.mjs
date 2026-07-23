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

const result = spawnSync(binaryPath, [], {
  encoding: "utf8",
  timeout: 60_000,
});

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
  if (result.error) process.stderr.write(`spawn failed: ${result.error.message}\n`);
  if (mismatch) process.stderr.write(mismatch + "\n");
}

process.exitCode = failed ? (exitCode === 0 ? 1 : exitCode) : 0;
