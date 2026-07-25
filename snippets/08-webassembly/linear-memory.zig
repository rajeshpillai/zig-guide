//! title: Passing Data Across the Boundary
//! A wasm call takes only numbers: i32, i64, f32, f64. Anything larger (a
//! string, a buffer) lives in the module's linear memory and crosses as an
//! offset plus a length. The host writes into that memory, calls in, and reads
//! the result back out. The test simulates exactly what the JS host does.

const std = @import("std");

// A tiny arena the host can carve scratch space from. A real module would
// export a general allocator; this keeps the moving parts on screen.
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

    // Host: mutate in place, then read the bytes straight back.
    upperInPlace(dst, msg.len);
    try std.testing.expectEqualStrings("ZIG", dst[0..msg.len]);
}
