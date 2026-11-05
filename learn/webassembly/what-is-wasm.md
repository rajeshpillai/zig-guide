# What WebAssembly Is

> A portable binary target for a sandboxed stack machine, and how Zig compiles to it.

WebAssembly (wasm) is a binary instruction format for a stack machine. Wasm is
a compile *target*, not a language. You write Zig, C or Rust, and the compiler
emits a `.wasm` module. An engine (a browser, Node, wasmtime) loads that
module and runs it in a sandbox at almost native speed.

This site is an example. Each snippet that you read is Zig compiled to
`wasm32-wasi`. The Run button gives that exact module to a WASI shim in your
browser. Press the button below, and the code reports the target of its build.

```zig
const std = @import("std");
const builtin = @import("builtin");

pub fn main(init: std.process.Init) !void {
    var buf: [256]u8 = undefined;
    var fw = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &fw.interface;

    try out.print("cpu arch: {t}\n", .{builtin.target.cpu.arch});
    try out.print("os tag:   {t}\n", .{builtin.target.os.tag});
    try out.print("pointer:  {d} bits\n", .{@bitSizeOf(usize)});

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`08-webassembly.hello-wasm`)*

## Module, instance, linear memory

Three terms explain most of the model.

A **module** is the compiled `.wasm` file. It contains code and a description
of its imports and exports. A module does nothing alone, like a shared library
that is not loaded.

An **instance** is a module that an engine loaded and connected. The
instantiation resolves the imports of the module, which are functions that the
host supplies. It also gives the module its memory. You can instantiate the
same module more than one time. Each instance has its own state.

**Linear memory** is the heap of the instance. It is one flat, contiguous
array of bytes, with addresses from zero, and the module and the host both see
it. It starts at a number of 64 KiB pages and can grow. A Zig pointer inside a
wasm module is only an offset into this array. The module cannot touch any
other memory.

## Only numbers go through a call

A call can carry only these types: `i32`, `i64`, `f32` and `f64`. Later
proposals added `v128` for SIMD and reference types for host objects. But a
JavaScript host still gives numbers. A call cannot give or return a string, a
struct or an array.

Larger data goes as bytes in linear memory. An `i32` offset and, usually, an
`i32` length identify the bytes. A Zig `[]const u8` slice becomes a pointer
and a length. At the wasm boundary, that is two `i32` values. The [linear
memory recipe](../linear-memory/) shows the full pattern.

## The sandbox

A wasm module has no ambient authority. By default, it gets access to nothing.
Alone, it cannot open a file, read the clock or make a network call. It can do
only what its imports let it do. If a module gets no imports, it can only
calculate.

The capability comes from the host, not from the binary. Thus the same `.wasm`
runs without change in a browser tab and on a server. For the same reason, it
is reasonable to run a module that you do not trust. It is not reasonable to
run a native binary that you do not trust.

## Three ways that Zig compiles to wasm

The difference is the target triple that you give. The triple decides what the
sandbox can get to.

| Target | What it gives you | Use it for |
| --- | --- | --- |
| `wasm32-freestanding` | Only wasm itself. No libc, no OS. You export functions and manage memory. | Modules that a JavaScript or native host controls. |
| `wasm32-wasi` | A system interface with the shape of POSIX: files, args, clock, stdout, an entry point. | Command-line programs that run under Node, wasmtime or Wasmer. |
| `wasm32-emscripten` | The Emscripten runtime and its libc/JS glue. | A port of a large C/C++ codebase that expects that environment. |

This guide verifies against `wasm32-wasi`, because the guide needs stdout to
compare. The [freestanding recipe](../freestanding/) shows the smaller target.

## Command and reactor

There are two shapes of module. The difference is if the module has an entry
point.

A **command** has a `_start` function. The engine calls `_start` one time. It
runs to completion like a `main`, and then the instance is complete. Each WASI
program in this guide is a command. A Zig file with `pub fn main` compiles to a
command.

A **reactor** has no entry point. The engine instantiates the reactor, and then
calls its exported functions when necessary, many times. The instance stays
alive between calls. Use this shape when JavaScript calls into Zig. To build a
reactor, use `-fno-entry` and give the names of the functions to export.

The shape that you need decides which recipe applies. The next pages build
each shape.
