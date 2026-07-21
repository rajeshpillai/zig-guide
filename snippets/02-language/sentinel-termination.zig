//! title: Sentinel Termination
//! Sequences that end with a known marker value, usually 0.

const std = @import("std");
const expect = std.testing.expect;

test "sentinel-terminated array" {
    // `[3:0]u8` is three bytes plus a guaranteed 0 at index 3.
    const array: [3:0]u8 = .{ 1, 2, 3 };
    try expect(array.len == 3); // the sentinel is not counted
    try expect(array[3] == 0); // but it is there
}

test "string literals are sentinel terminated" {
    const literal = "hi";
    try expect(@TypeOf(literal) == *const [2:0]u8);
    try expect(literal.len == 2);
    try expect(literal[2] == 0); // free C compatibility
}

test "span recovers the length from a sentinel" {
    const c_string: [*:0]const u8 = "hello";
    // `[*:0]T` has no length, but the sentinel makes it recoverable.
    const slice = std.mem.span(c_string);
    try expect(slice.len == 5);
    try expect(std.mem.eql(u8, slice, "hello"));
}

test "sentinel slices coerce to ordinary ones" {
    const sentinel_slice: [:0]const u8 = "abc";
    const plain: []const u8 = sentinel_slice;
    try expect(plain.len == 3);
}
