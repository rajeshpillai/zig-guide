/**
 * Runs a `wasm32-wasi` module in the browser and returns what it wrote.
 *
 * This is the client-side twin of `tools/run-wasi.mjs`: the same `.wasm` that
 * `zig build verify` executed under Node during CI is fetched and executed here.
 * If it passed CI, it will behave identically for the reader.
 */
import {
  WASI,
  File,
  OpenFile,
  ConsoleStdout,
  OpenDirectory,
  PreopenDirectory,
  type Fd,
} from "@bjorn3/browser_wasi_shim";

// The shim creates a directory by opening it with CREAT|DIRECTORY and no EXCL,
// so creating one that already exists succeeds. A real disk and Node's WASI
// both return EEXIST, and `zig build verify` runs under Node, so without this
// the Directories chapter would print one thing in CI and another here. Still
// the case in 0.4.2, the latest release; drop this when upstream adds EXCL.
const OFLAGS_CREAT = 1;
const OFLAGS_DIRECTORY = 2;
const OFLAGS_EXCL = 4;
OpenDirectory.prototype.path_create_directory = function (path: string) {
  return this.path_open(0, path, OFLAGS_CREAT | OFLAGS_DIRECTORY | OFLAGS_EXCL, 0n, 0n, 0).ret;
};

export interface RunResult {
  /** Interleaved stdout+stderr, in the order the program emitted it. */
  output: string;
  exitCode: number;
  /** Wall-clock duration of `wasi.start`, in milliseconds. */
  durationMs: number;
}

/** Cache compiled modules so re-running a snippet skips recompilation. */
const moduleCache = new Map<string, Promise<WebAssembly.Module>>();

/**
 * A module whose only function body is `v128.const 0; i8x16.popcnt`. An engine
 * without WebAssembly SIMD rejects it at validation, which is the only reliable
 * way to ask: the feature has no `WebAssembly.*` surface to check for.
 */
const SIMD_PROBE = Uint8Array.of(
  0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00, 0x01, 0x05, 0x01, 0x60, 0x00,
  0x01, 0x7b, 0x03, 0x02, 0x01, 0x00, 0x0a, 0x0a, 0x01, 0x08, 0x00, 0x41, 0x00,
  0xfd, 0x0f, 0xfd, 0x62, 0x0b,
);

let simdSupported: boolean | null = null;
function hasSimd(): boolean {
  simdSupported ??= WebAssembly.validate(SIMD_PROBE);
  return simdSupported;
}

/**
 * `compileStreaming` requires the response to carry `application/wasm`. Static
 * hosts do not all send it, and a wrong type fails the whole page rather than
 * degrading — so fall back to buffering the bytes ourselves.
 */
async function compileFrom(url: string): Promise<WebAssembly.Module> {
  const response = await fetch(url);
  if (!response.ok) {
    throw new Error(`could not fetch ${url} (HTTP ${response.status})`);
  }
  try {
    try {
      return await WebAssembly.compileStreaming(response.clone());
    } catch {
      return await WebAssembly.compile(await response.arrayBuffer());
    }
  } catch (err) {
    // Only the chapters that teach vectors are built with `simd128`, so an
    // engine without it reaches this for those four snippets and no others.
    // Raw, the failure reads "unrecognized opcode: fd 0", which tells the
    // reader nothing about what to do next.
    if (!hasSimd()) {
      throw new Error(
        "This snippet is compiled with WebAssembly SIMD, which this browser " +
          "cannot run. Chrome needs 91+, Safari 16.4+, and Firefox 89+ on an " +
          "x86 CPU with SSE4.1. Only the four vector chapters need it; every " +
          "other snippet on the site runs here.",
      );
    }
    throw err;
  }
}

function compile(url: string): Promise<WebAssembly.Module> {
  let cached = moduleCache.get(url);
  if (!cached) {
    cached = compileFrom(url);
    // A failed compile must not be cached, or a transient network error
    // would poison the snippet for the rest of the session.
    cached.catch(() => moduleCache.delete(url));
    moduleCache.set(url, cached);
  }
  return cached;
}

export async function runWasm(
  url: string,
  { argv = ["snippet"], env = [] as string[] } = {},
): Promise<RunResult> {
  const chunks: string[] = [];
  const decoder = new TextDecoder("utf-8", { fatal: false });
  // Raw capture rather than `ConsoleStdout.lineBuffered`, which drops any
  // trailing partial line — `zig test` relies on non-newline-terminated writes.
  const sink = (bytes: Uint8Array) =>
    chunks.push(decoder.decode(bytes, { stream: true }));

  const fds: Fd[] = [
    new OpenFile(new File([])), // stdin: always empty
    new ConsoleStdout(sink), // stdout
    new ConsoleStdout(sink), // stderr — zig test reports here
    // An empty in-memory directory at descriptor 3, which Zig's std takes to
    // be the current directory. A new one per run, so pressing Run twice
    // starts from the same empty state CI did. `tools/run-wasi.mjs` preopens
    // an empty temp directory in the same slot.
    new PreopenDirectory(".", new Map()),
  ];

  const wasi = new WASI(argv, env, fds, { debug: false });
  const module = await compile(url);
  const instance = await WebAssembly.instantiate(module, {
    wasi_snapshot_preview1: wasi.wasiImport,
  });

  const started = performance.now();
  let exitCode = 0;
  try {
    // `start` handles WASIProcExit internally and returns the exit code;
    // anything it rethrows is a genuine trap (unreachable, OOB, panic).
    exitCode = wasi.start(instance as never);
  } catch (err) {
    chunks.push(`\ntrapped: ${err instanceof Error ? err.message : String(err)}\n`);
    exitCode = 134;
  }

  return {
    output: chunks.join(""),
    exitCode,
    durationMs: performance.now() - started,
  };
}
