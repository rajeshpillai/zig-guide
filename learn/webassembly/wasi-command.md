# Recipe: A WASI Command

> Compile a Zig program to wasm and run it from a shell under any WASI runtime.

## The problem

You have a Zig program with a `main`, and you want a single `.wasm` that runs
the same on Linux, macOS, and Windows, without recompiling. WASI is the piece
that makes it possible: it is the system interface a wasm command calls for the
OS-shaped things (stdout here) that pure wasm cannot do.

## The plan

1. Write an ordinary Zig program. Nothing about it is wasm-specific.
2. Build it for `wasm32-wasi`.
3. Run the `.wasm` under a WASI runtime.

```zig
const std = @import("std");

const document =
    \\zig compiles to wasm
    \\wasm runs in the browser
    \\the browser runs this page
;

pub fn main(init: std.process.Init) !void {
    var buf: [256]u8 = undefined;
    var fw = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &fw.interface;

    var lines: usize = 0;
    var words: usize = 0;
    var it = std.mem.splitScalar(u8, document, '\n');
    while (it.next()) |line| {
        lines += 1;
        var w = std.mem.tokenizeScalar(u8, line, ' ');
        while (w.next()) |_| words += 1;
    }

    try out.print("lines: {d}\n", .{lines});
    try out.print("words: {d}\n", .{words});
    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`08-webassembly.wasi-command`)*

The source is a normal program. It splits an embedded document, counts lines
and words, and writes the totals to stdout through the `Io` instance `main`
receives. There is no wasm ceremony in the code, which is the point.

## Building it

```bash
zig build-exe wasi-command.zig -target wasm32-wasi -O ReleaseSmall
```

That emits `wasi-command.wasm`. `-O ReleaseSmall` matters more here than on a
native build: the module is a file you ship or fetch, and the debug build is
roughly thirty times larger. This guide's `build.zig` defaults to that mode for
exactly this reason.

## Running it

The module is not tied to a browser. Any WASI runtime executes it:

```bash
wasmtime wasi-command.wasm
# lines: 3
# words: 14

wasmer wasi-command.wasm      # same output
node --experimental-wasi-unstable-preview1 run.mjs   # via node:wasi
```

The Node path is what CI and this page's Run button use. The runner
(`tools/run-wasi.mjs` in this repo) is about forty lines: it opens the module,
builds a WASI import object, and calls `_start`.

## What WASI is doing

The program calls `writeStreamingAll` to print. On a native build that lowers to
a `write` syscall. On `wasm32-wasi` it lowers to a call to an imported function,
`fd_write`, that the module does not contain. The runtime supplies it at
instantiation. Swap the runtime and stdout goes somewhere else (a real terminal
under wasmtime, a captured buffer under this page's shim) with the module byte
for byte the same.

The capability is the runtime's to grant. A runtime can refuse to preopen any
directories, and then the identical program can print but cannot read a file.
That refusal is the sandbox from the [overview](../what-is-wasm/) made concrete.

## Variations

- **Arguments and env:** WASI passes `argv` and environment variables when the
  runtime chooses to. `std.process.argsAlloc` reads them exactly as on native.
- **Files:** `std.fs` works, but only inside directories the runtime preopened.
  Nothing else on disk is reachable, by construction.
- **Exit status:** returning an error from `main` sets a non-zero exit code, and
  the runtime reports it, so wasm commands compose in shell pipelines like any
  other tool.
