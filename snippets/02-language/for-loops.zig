//! title: For Loops
//! `for` iterates over slices, arrays, and ranges — never a bare counter.

const std = @import("std");
const expect = std.testing.expect;

test "iterate values" {
    const string = [_]u8{ 'a', 'b', 'c' };
    var count: usize = 0;
    for (string) |character| {
        if (character == 'b') count += 1;
    }
    try expect(count == 1);
}

test "iterate with an index" {
    const string = [_]u8{ 'a', 'b', 'c' };
    var last_index: usize = 0;
    for (string, 0..) |_, index| {
        last_index = index;
    }
    try expect(last_index == 2);
}

test "ranges" {
    var sum: usize = 0;
    for (0..5) |i| sum += i;
    try expect(sum == 10);
}

test "iterate two sequences at once" {
    // Multi-object `for` requires equal lengths; a mismatch is checked.
    const names = [_][]const u8{ "a", "b" };
    const scores = [_]u8{ 1, 2 };
    var total: u8 = 0;
    for (names, scores) |name, score| {
        _ = name;
        total += score;
    }
    try expect(total == 3);
}

test "mutate through a pointer capture" {
    var numbers = [_]u8{ 1, 2, 3 };
    for (&numbers) |*n| n.* *= 2;
    try expect(numbers[2] == 6);
}
