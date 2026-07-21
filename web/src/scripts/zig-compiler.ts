/**
 * In-browser Zig compiler.
 *
 * The Zig compiler is itself compiled to `wasm32-wasi` and driven here exactly
 * like a CLI invocation: we hand it a virtual filesystem containing the user's
 * source plus the Zig standard library, run it with `build-exe`/`test` argv,
 * then read the emitted module back out of that filesystem.
 *
 * Because no LLVM is available in this environment, the compiler must use its
 * self-hosted wasm backend — which is why the target is always `wasm32-wasi`.
 *
 * Artifacts are produced by `tools/build-browser-compiler.sh` and are NOT
 * checked in; see the README. Until they exist, `loadZigCompiler` rejects with
 * an actionable message rather than failing obscurely.
 */
import {
  WASI,
  File,
  Directory,
  OpenFile,
  ConsoleStdout,
  PreopenDirectory,
  type Fd,
} from "@bjorn3/browser_wasi_shim";

export interface ZigCompiler {
  /** Compile `source` and resolve to a blob URL for the emitted `.wasm`. */
  compile(source: string, kind: "exe" | "test"): Promise<string>;
}

export class CompileError extends Error {
  constructor(readonly diagnostics: string) {
    super(diagnostics);
    this.name = "CompileError";
  }
}

const base = import.meta.env.BASE_URL;
const COMPILER_URL = `${base}compiler/zig.wasm`;
const STDLIB_URL = `${base}compiler/lib.tar`;

async function fetchRequired(url: string, what: string): Promise<ArrayBuffer> {
  const res = await fetch(url);
  if (!res.ok) {
    throw new Error(
      `The in-browser Zig compiler is not available (${what} missing at ${url}, ` +
        `HTTP ${res.status}). Run tools/build-browser-compiler.sh to produce it. ` +
        `Unedited snippets still run from their prebuilt wasm.`,
    );
  }
  return res.arrayBuffer();
}

/** Expand an uncompressed tar into an in-memory WASI directory tree. */
function untar(buffer: ArrayBuffer): Directory {
  const root = new Directory(new Map());
  const bytes = new Uint8Array(buffer);
  const decoder = new TextDecoder();

  for (let offset = 0; offset + 512 <= bytes.length; ) {
    const header = bytes.subarray(offset, offset + 512);
    if (header[0] === 0) break; // two zero blocks terminate the archive

    const name = decoder.decode(header.subarray(0, 100)).replace(/\0.*$/, "");
    const size = parseInt(decoder.decode(header.subarray(124, 136)).replace(/\0.*$/, "").trim(), 8) || 0;
    const typeFlag = String.fromCharCode(header[156]);
    offset += 512;

    if (typeFlag === "0" || typeFlag === "") {
      const contents = bytes.slice(offset, offset + size);
      insert(root, name, new File(contents));
    }
    offset += Math.ceil(size / 512) * 512;
  }
  return root;
}

/**
 * Insert `file` at `path`, creating intermediate directories as needed.
 * Note `Directory.contents` is a `Map`, not a plain object.
 */
function insert(root: Directory, path: string, file: File): void {
  const parts = path.split("/").filter((p) => p && p !== ".");
  const name = parts.pop();
  if (!name) return;

  let dir = root;
  for (const part of parts) {
    let next = dir.contents.get(part);
    if (!(next instanceof Directory)) {
      next = new Directory(new Map());
      dir.contents.set(part, next);
    }
    dir = next as Directory;
  }
  dir.contents.set(name, file);
}

export async function loadZigCompiler(): Promise<ZigCompiler> {
  const [compilerBytes, stdlibBytes] = await Promise.all([
    fetchRequired(COMPILER_URL, "zig.wasm"),
    fetchRequired(STDLIB_URL, "lib.tar"),
  ]);

  const module = await WebAssembly.compile(compilerBytes);
  const stdlib = untar(stdlibBytes);

  return {
    async compile(source: string, kind: "exe" | "test"): Promise<string> {
      const cwd = new Directory(new Map());
      cwd.contents.set("main.zig", new File(new TextEncoder().encode(source)));

      const diagnostics: string[] = [];
      const fds: Fd[] = [
        new OpenFile(new File([])),
        ConsoleStdout.lineBuffered((l) => diagnostics.push(l)),
        ConsoleStdout.lineBuffered((l) => diagnostics.push(l)),
        new PreopenDirectory("/lib", stdlib.contents),
        new PreopenDirectory("/work", cwd.contents),
      ];

      const argv = [
        "zig",
        kind === "test" ? "test" : "build-exe",
        "/work/main.zig",
        "-target",
        "wasm32-wasi",
        "-OReleaseSmall",
        "--zig-lib-dir",
        "/lib",
        "-femit-bin=/work/out.wasm",
      ];
      if (kind === "test") argv.push("--test-no-exec");

      const wasi = new WASI(argv, [], fds, { debug: false });
      const instance = await WebAssembly.instantiate(module, {
        wasi_snapshot_preview1: wasi.wasiImport,
      });

      let exitCode = 0;
      try {
        exitCode = wasi.start(instance as never);
      } catch (err) {
        diagnostics.push(err instanceof Error ? err.message : String(err));
        exitCode = 1;
      }

      const emitted = cwd.contents.get("out.wasm");
      if (exitCode !== 0 || !(emitted instanceof File)) {
        throw new CompileError(diagnostics.join("\n") || "compilation failed");
      }

      return URL.createObjectURL(
        new Blob([emitted.data as unknown as BlobPart], { type: "application/wasm" }),
      );
    },
  };
}
