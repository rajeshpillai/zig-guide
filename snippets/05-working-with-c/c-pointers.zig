//! title: C Pointers
//! `[*c]T` exists for translated C headers. Avoid it elsewhere.

const std = @import("std");
const expect = std.testing.expect;

test "a C pointer is the permissive one" {
    var value: i32 = 42;
    // [*c]T can be null, can be indexed, and coerces freely. It gives up
    // every guarantee Zig's other pointer types provide.
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

    // The length is not carried by the pointer; supply it once, then work
    // with a bounds-checked slice.
    const slice: []i32 = c_ptr[0..3];
    try expect(slice.len == 3);
    try expect(slice[1] == 20);
}
