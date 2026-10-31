# Recipe: A Freestanding Module

> The smallest wasm target, with no WASI and no libc, and the memory builtins that replace them.

`wasm32-freestanding` is the smallest wasm target of Zig, with no WASI and no
libc. The module has no `main`, no stdout, no files and no OS heap. Its host
controls the module through exports.

## The problem

You want the smallest possible module, with no dependency on a system
interface. A JavaScript host or a native embedder controls the module. Thus
the files and clocks of WASI only add weight that the module does not use.

## The plan

1. Write functions that do not need an OS: no files, no stdout, no `main`.
2. Supply your own memory, because no system allocator is available.
3. Build for `wasm32-freestanding`.

```zig
const std = @import("std");

// Freestanding has no OS heap. Thus give the allocator a fixed backing store
// inside the linear memory of the module.
var heap: [64 * 1024]u8 = undefined;
var fba = std.heap.FixedBufferAllocator.init(&heap);

export fn sumRange(n: u32) u64 {
    var total: u64 = 0;
    var i: u32 = 1;
    while (i <= n) : (i += 1) total += i;
    return total;
}

// Ask the engine for one more 64 KiB page of linear memory, and report the
// previous size in pages. This is a wasm builtin. It needs no OS.
export fn growOnePage() i32 {
    return @wasmMemoryGrow(0, 1);
}

test sumRange {
    try std.testing.expectEqual(@as(u64, 55), sumRange(10));
}

test "a fixed buffer allocator needs no OS" {
    const a = fba.allocator();
    const s = try a.alloc(u8, 8);
    defer a.free(s);
    try std.testing.expectEqual(@as(usize, 8), s.len);
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`08-webassembly.freestanding`)*

The tests here run because the guide builds each snippet for `wasm32-wasi` to
verify it. For freestanding, the source does not change, because no line in it
touches WASI. Only the target in the build command is different. The next
section gives that command.

## Build for freestanding

```bash
zig build-exe freestanding.zig \
  -target wasm32-freestanding \
  -O ReleaseSmall -fno-entry \
  --export=sumRange --export=growOnePage
```

These are the same reactor flags as in the [JavaScript
recipe](../export-to-js/). The only change is `-target wasm32-freestanding` in
place of `wasm32-wasi`.

That one change removes the full WASI import layer. The module imports nothing
at all. It needs no runtime, only a bare wasm engine.

## What freestanding removes

Freestanding removes everything that has the shape of an OS, because there is
no OS:

- **No `main` / `_start`.** There is no entry point to call. The host gets into
  the module through the exports.
- **No stdout, files, clock or sockets.** Files and clocks are now behind
  `std.Io`, and freestanding has no `Io` implementation to give to the code.
  There is nothing to lower the calls onto. Thus a use of them is a compile
  error, not a failure at run time.
- **No OS heap.** There is no `mmap` under the code. But
  `std.heap.page_allocator` still works. On wasm, it uses `@wasmMemoryGrow`,
  not the OS. The general-purpose allocator works on top of it.

The snippet uses the simpler method. It gives a `FixedBufferAllocator` a 64
KiB static array. That array is in linear memory, which is the only memory
that exists. The allocator never calls the OS, because there is no OS to call.

## The memory builtins

Freestanding does not limit you to the memory that the module started with.
Two wasm builtins manage linear memory directly, with no runtime under them:

- `@wasmMemorySize(0)` returns the current size in 64 KiB pages.
- `@wasmMemoryGrow(0, n)` asks the engine for `n` more pages. It returns the
  previous size, or `-1` if the engine refuses.

`growOnePage` in the snippet uses the second builtin. When its buffer is full,
a real allocator calls this builtin. Then it divides the new pages into
allocations.

This is the layer under the fixed buffer. When a freestanding module needs
more memory than it got at compile time, the bytes come from here.

## When to select freestanding and not WASI

Select freestanding when a host can give the module all that it needs, and you
want the module itself to carry nothing extra. A browser is such a host. A
native program that embeds wasmtime is also such a host.

Select WASI when the module is a full program that must run from a shell and do
the work of an OS program. The [command recipe](../wasi-command/) covers that
case. This recipe covers the opposite case.
