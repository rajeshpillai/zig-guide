//! title: Many-item Pointers
//! `[*]T` points at an unknown number of `T`, with no length attached.

const std = @import("std");
const expect = std.testing.expect;

test "many-item pointers support indexing" {
    var array = [_]u8{ 1, 2, 3, 4 };
    const many: [*]u8 = &array;

    // You can use an index and pointer arithmetic. But there is no `.len`,
    // thus there is no bounds check. You must make sure that the range is correct.
    try expect(many[0] == 1);
    try expect(many[3] == 4);
}

test "convert to a slice by supplying the length" {
    var array = [_]u8{ 1, 2, 3, 4 };
    const many: [*]u8 = &array;

    // `[*]T` does not have the length. Add the length, and you get a `[]T`.
    // The compiler adds bounds checks to a `[]T` again.
    const slice: []u8 = many[0..3];
    try expect(slice.len == 3);
}

test "single-item pointers do not index" {
    // A `*T` is one item. `ptr[1]` is a compile error. For this reason, Zig
    // has the two types `*T` and `[*]T`, and C has only `T*`.
    var x: u8 = 9;
    const single: *u8 = &x;
    try expect(single.* == 9);
}
