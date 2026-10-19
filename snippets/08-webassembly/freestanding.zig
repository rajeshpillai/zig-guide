//! title: A Freestanding Module
//! wasm32-freestanding removes WASI and libc: no files, no clock, no stdout,
//! no `main`. You export functions and own each byte of memory. CI builds this
//! for wasm32-wasi to run the tests. For freestanding, the source does not
//! change. The prose gives the one-line build command that changes the target.

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
