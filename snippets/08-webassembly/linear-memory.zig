//! title: Passing Data Across the Boundary
//! A wasm call takes only numbers: i32, i64, f32, f64. Larger data (a string,
//! a buffer) is in the linear memory of the module, and it goes across as an
//! offset and a length. The host writes into that memory, calls in, and reads
//! the result back. The test does exactly the steps of the JS host.

const std = @import("std");

// A small arena that gives scratch space to the host. A real module exports
// a general allocator. This arena keeps each step visible in the code.
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

// Sum the bytes that the host put at ptr[0..len].
export fn sumBytes(ptr: [*]const u8, len: usize) u32 {
    var total: u32 = 0;
    for (ptr[0..len]) |b| total += b;
    return total;
}

// Change to upper case in place. Thus the host reads the answer from the
// same offset.
export fn upperInPlace(ptr: [*]u8, len: usize) void {
    for (ptr[0..len]) |*b| b.* = std.ascii.toUpper(b.*);
}

test "the round trip a JS host would drive" {
    reset();

    // Host: reserve space, and copy bytes into linear memory.
    const msg = "zig";
    const dst = alloc(msg.len);
    @memcpy(dst[0..msg.len], msg);

    // Host: call in with (offset, length).
    try std.testing.expectEqual(@as(u32, 'z' + 'i' + 'g'), sumBytes(dst, msg.len));

    // Host: change the bytes in place, then read them back.
    upperInPlace(dst, msg.len);
    try std.testing.expectEqualStrings("ZIG", dst[0..msg.len]);
}
