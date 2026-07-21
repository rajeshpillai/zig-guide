//! title: Inline Loops
//! Unroll at compile time, so each iteration can have its own types.

const std = @import("std");
const expect = std.testing.expect;

test "inline for over a tuple" {
    // A tuple's elements have different types, so the loop body must be
    // compiled separately for each — that is what `inline` provides.
    const tuple = .{ @as(u8, 1), @as(f32, 2.5), true };
    var count: usize = 0;
    inline for (tuple) |value| {
        if (@TypeOf(value) == bool) count += 10 else count += 1;
    }
    try expect(count == 12);
}

test "inline for over types" {
    const types = [_]type{ u8, u16, u32 };
    var total: usize = 0;
    inline for (types) |T| {
        total += @sizeOf(T);
    }
    try expect(total == 7);
}

test "the loop variable becomes comptime-known" {
    var sum: usize = 0;
    inline for (0..4) |i| {
        // `i` is comptime here, so it can be used where a comptime value
        // is required — such as an array type's length.
        const arr: [i]u8 = undefined;
        sum += arr.len;
    }
    try expect(sum == 6); // 0 + 1 + 2 + 3
}
