//! title: Imports
//! `@import` returns a file as a struct; `pub` controls what escapes.

const std = @import("std");
const expect = std.testing.expect;

// A relative path imports another source file. The result is a struct type
// whose declarations are that file's `pub` declarations.
const shapes = @import("_shapes.zig");

test "use an imported declaration" {
    try expect(shapes.double(21) == 42);
}

test "imported types work like any other" {
    const c = shapes.Circle{ .radius = 2 };
    try expect(c.area() > 12.5 and c.area() < 12.6);
}

test "a file is a struct" {
    // `@This()` inside a file refers to that file's implicit struct type,
    // which is why `@import` can return something you access with `.`.
    try expect(@TypeOf(shapes) == type);
    try expect(shapes.pi > 3.14);
}

test "std is just another import" {
    // `@import("std")` is the same mechanism, resolved by the compiler
    // rather than by path.
    try expect(std.mem.eql(u8, "a", "a"));
}
