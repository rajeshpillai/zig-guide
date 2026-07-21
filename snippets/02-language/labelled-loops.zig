//! title: Labelled Loops
//! Break or continue an outer loop by name.

const std = @import("std");
const expect = std.testing.expect;

test "break out of nested loops" {
    var found: ?[2]usize = null;
    outer: for (0..5) |i| {
        for (0..5) |j| {
            if (i * j == 6) {
                found = .{ i, j };
                break :outer; // leaves both loops
            }
        }
    }
    try expect(found.?[0] == 2);
    try expect(found.?[1] == 3);
}

test "continue an outer loop" {
    var count: u32 = 0;
    outer: for (0..4) |i| {
        for (0..4) |j| {
            if (j > i) continue :outer; // next i, skip remaining j
            count += 1;
        }
    }
    try expect(count == 10); // 1 + 2 + 3 + 4
}

test "labelled loops yield values too" {
    const first_square_over_20 = blk: {
        for (0..10) |i| {
            if (i * i > 20) break :blk i;
        }
        break :blk 0;
    };
    try expect(first_square_over_20 == 5);
}
