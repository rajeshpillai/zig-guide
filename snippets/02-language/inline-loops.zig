//! title: Inline Loops
//! Unroll at compile time. Then each iteration can have its own types.

const std = @import("std");
const expect = std.testing.expect;

test "inline for over a tuple" {
    // The elements of a tuple have different types. Thus the compiler must
    // compile the loop body separately for each element. `inline` does this.
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
        // `i` is comptime here. Thus you can use `i` where a comptime value
        // is necessary, for example the length of an array type.
        const arr: [i]u8 = undefined;
        sum += arr.len;
    }
    try expect(sum == 6); // 0 + 1 + 2 + 3
}
