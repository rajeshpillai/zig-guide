//! title: Slices
//! `[]T` is a pointer plus a length, the workhorse of Zig code.

const std = @import("std");
const expect = std.testing.expect;

fn total(values: []const u8) u32 {
    var sum: u32 = 0;
    for (values) |v| sum += v;
    return sum;
}

test "slicing an array" {
    var array = [_]u8{ 1, 2, 3, 4, 5 };
    const slice = array[1..4]; // end is exclusive
    try expect(slice.len == 3);
    try expect(total(slice) == 9);
}

test "slices share memory" {
    var array = [_]u8{ 1, 2, 3 };
    const slice = array[0..2];
    slice[0] = 100;
    try expect(array[0] == 100); // no copy was made
}

test "strings are slices" {
    // A string literal is a `*const [N:0]u8` (a pointer to a
    // null-terminated array), which coerces to `[]const u8`.
    const message: []const u8 = "hello";
    try expect(message.len == 5);
    try expect(std.mem.eql(u8, message[0..2], "he"));
}

test "slicing to the end" {
    const array = [_]u8{ 1, 2, 3, 4 };
    const rest = array[2..];
    try expect(rest.len == 2);
}
