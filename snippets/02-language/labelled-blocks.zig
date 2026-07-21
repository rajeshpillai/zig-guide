//! title: Labelled Blocks
//! A block that produces a value.

const std = @import("std");
const expect = std.testing.expect;

test "block as an expression" {
    // `break :label value` yields a value from the labelled block, so a
    // multi-step computation can still produce a single const.
    const count = blk: {
        var sum: u32 = 0;
        for (0..10) |i| sum += i;
        break :blk sum;
    };
    try expect(count == 45);
    try expect(@TypeOf(count) == u32);
}

test "labels also name scopes for shadowing" {
    const outer_value: u32 = 1;
    const result = blk: {
        const outer_value_inner: u32 = 2;
        break :blk outer_value + outer_value_inner;
    };
    try expect(result == 3);
}
