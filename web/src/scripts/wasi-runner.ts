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
  type Fd,
} from "@bjorn3/browser_wasi_shim";

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
    return await WebAssembly.compileStreaming(response.clone());
  } catch {
    return WebAssembly.compile(await response.arrayBuffer());
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
