# Recipe: Passing Data Across the Boundary

> Move strings and buffers between JavaScript and wasm through shared linear memory.

A string cannot cross between JavaScript and a Zig wasm module as a value, so
it crosses through the module's linear memory: the host writes the bytes at an
offset the module's exported `alloc` returns, then calls in with that offset
and a length.

## The problem

The [last recipe](../export-to-js/) passed numbers, which fit in a wasm value.
A string does not. Neither does a slice, a struct, or a buffer. Linear memory
is the only place both sides can see them, and the two sides must agree on
what the bytes there mean.

## The plan

1. Export an `alloc` so the host can reserve space in linear memory.
2. Export the memory (the reactor build does this automatically).
3. The host writes bytes at the returned offset, then calls in with `(offset,
   len)`. It reads any result back from memory at an offset the module reports.

```zig
const std = @import("std");

// A small arena the host can take scratch space from. A real module would
// export a general allocator. This one keeps every step visible in the code.
var scratch: [4096]u8 = undefined;
var used: usize = 0;

export fn alloc(len: usize) [*]u8 {
    const start = used;
    used += len;
    return scratch[start..].ptr;
}

export fn reset() void {
    used = 0;
}

// Sum the bytes the host placed at ptr[0..len].
export fn sumBytes(ptr: [*]const u8, len: usize) u32 {
    var total: u32 = 0;
    for (ptr[0..len]) |b| total += b;
    return total;
}

// Uppercase in place, so the host reads the answer from the same offset.
export fn upperInPlace(ptr: [*]u8, len: usize) void {
    for (ptr[0..len]) |*b| b.* = std.ascii.toUpper(b.*);
}

test "the round trip a JS host would drive" {
    reset();

    // Host: reserve space, copy bytes into linear memory.
    const msg = "zig";
    const dst = alloc(msg.len);
    @memcpy(dst[0..msg.len], msg);

    // Host: call in with (offset, length).
    try std.testing.expectEqual(@as(u32, 'z' + 'i' + 'g'), sumBytes(dst, msg.len));

    // Host: change the bytes in place, then read them back.
    upperInPlace(dst, msg.len);
    try std.testing.expectEqualStrings("ZIG", dst[0..msg.len]);
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`08-webassembly.linear-memory`)*

The test in the snippet is the host's script written in Zig: reserve space, copy
bytes in, call `sumBytes`, mutate in place with `upperInPlace`, read the bytes
back. A JavaScript host does the same steps through `instance.exports` and
a typed-array view. Building it as a reactor and calling it is the
[browser recipe](../browser-instantiate/). This page covers the memory
protocol itself.

## Why an offset and not a pointer

A Zig `[*]u8` inside a wasm module is an offset into linear memory, counted from
zero. It is not an address in the host's process. When `alloc` returns `[*]u8`,
JavaScript sees a plain integer: where in the shared array the bytes go. The
host never dereferences a wasm pointer directly. It indexes the memory buffer at
that number.

## The JavaScript side

`WebAssembly.Memory` exposes an `ArrayBuffer` you view with typed arrays. The
protocol is only writing into it and reading back out:

```js
const { instance } = await WebAssembly.instantiate(bytes, {});
const { alloc, reset, sumBytes, upperInPlace, memory } = instance.exports;

function pass(str) {
  const utf8 = new TextEncoder().encode(str);
  const ptr = alloc(utf8.length);
  // A fresh view each time: growing memory detaches the old ArrayBuffer.
  new Uint8Array(memory.buffer, ptr, utf8.length).set(utf8);
  return { ptr, len: utf8.length };
}

reset();
const { ptr, len } = pass("zig");
console.log(sumBytes(ptr, len));        // 330  (z + i + g)

upperInPlace(ptr, len);
const out = new Uint8Array(memory.buffer, ptr, len);
console.log(new TextDecoder().decode(out));   // "ZIG"
```

## The one trap

`memory.buffer` can change. When the module grows its linear memory (any
allocation might), the old `ArrayBuffer` is *detached* and every typed array
over it reads as empty. So build the `Uint8Array` view right before you use it.
Never cache it across a call that might allocate. The `pass` helper above takes
a fresh view each time for exactly this reason.

## Who owns the memory

In this snippet the module owns it: `alloc` hands out slices of a fixed 4 KiB
buffer, and `reset` reclaims all of it at once. This is a bump allocator. It is enough
for request-scoped work where the host fills a buffer, calls, and moves on. For
longer-lived data, export a real allocator (`free` included) or have the host
track the offsets it was given. Either way the rule holds: the module manages
its linear memory, and the host only reaches in at offsets the module handed out.

## Variations

- **Returning a string:** the module cannot return a slice. Return an offset and
  expose the length through a second export, or write both into a small struct
  in memory and return that struct's offset.
- **Strings are UTF-8 on both ends:** Zig source is UTF-8 and JavaScript's
  `TextEncoder` emits UTF-8, so bytes copied across need no re-encoding.
- **Growing on demand:** `alloc` here cannot fail usefully. A real one calls
  `@wasmMemoryGrow` when the buffer is exhausted, which the
  [freestanding recipe](../freestanding/) shows.
