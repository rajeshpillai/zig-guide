//! title: C Pointers
//! `[*c]T` exists for translated C headers. Avoid it elsewhere.

const std = @import("std");
const expect = std.testing.expect;

test "a C pointer is the permissive one" {
    var value: i32 = 42;
    // A [*c]T can be null, you can index it, and it coerces freely. It has
    // none of the guarantees of the other pointer types in Zig.
    const c_ptr: [*c]i32 = &value;
    try expect(c_ptr.* == 42);
    try expect(c_ptr[0] == 42);
}

test "it coerces to and from the safe types" {
    var array = [_]i32{ 1, 2, 3 };
    const many: [*]i32 = &array;
    const c_ptr: [*c]i32 = many;
    const back: [*]i32 = c_ptr;
    try expect(back[2] == 3);
}

test "null is representable" {
    const c_ptr: [*c]i32 = null;
    try expect(c_ptr == null);
}

test "convert at the boundary and use real types inside" {
    var array = [_]i32{ 10, 20, 30 };
    const c_ptr: [*c]i32 = &array;

    // The pointer does not carry the length. Supply the length one time.
    // Then use a slice, which has bounds checks.
    const slice: []i32 = c_ptr[0..3];
    try expect(slice.len == 3);
    try expect(slice[1] == 20);
}
