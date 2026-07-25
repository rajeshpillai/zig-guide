//! title: A Freestanding Module
//! wasm32-freestanding drops WASI and libc entirely: no files, no clock, no
//! stdout, no `main`. You export functions and own every byte of memory. This
//! is built for wasm32-wasi so the tests can run, but the source is unchanged
//! for freestanding; the prose gives the one-line build command that switches
//! the target.

const std = @import("std");

// Freestanding has no OS heap to fall back on, so give the allocator a fixed
// backing store carved from the module's own linear memory.
var heap: [64 * 1024]u8 = undefined;
var fba = std.heap.FixedBufferAllocator.init(&heap);

export fn sumRange(n: u32) u64 {
    var total: u64 = 0;
    var i: u32 = 1;
    while (i <= n) : (i += 1) total += i;
    return total;
}

// Ask the engine for one more 64 KiB page of linear memory and report the
// previous size in pages. A wasm builtin: it needs no OS underneath.
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
