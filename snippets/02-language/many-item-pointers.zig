//! title: Many-item Pointers
//! `[*]T` points at an unknown number of `T` — no length attached.

const std = @import("std");
const expect = std.testing.expect;

test "many-item pointers support indexing" {
    var array = [_]u8{ 1, 2, 3, 4 };
    const many: [*]u8 = &array;

    // Indexing and pointer arithmetic are allowed, but there is no `.len`
    // and therefore no bounds checking. You are responsible for the range.
    try expect(many[0] == 1);
    try expect(many[3] == 4);
}

test "convert to a slice by supplying the length" {
    var array = [_]u8{ 1, 2, 3, 4 };
    const many: [*]u8 = &array;

    // The length is the piece of information `[*]T` is missing; adding it
    // back yields a `[]T`, which is bounds-checked again.
    const slice: []u8 = many[0..3];
    try expect(slice.len == 3);
}

test "single-item pointers do not index" {
    // A `*T` is one item. `ptr[1]` is a compile error, which is the whole
    // reason Zig distinguishes `*T` from `[*]T` where C has only `T*`.
    var x: u8 = 9;
    const single: *u8 = &x;
    try expect(single.* == 9);
}
