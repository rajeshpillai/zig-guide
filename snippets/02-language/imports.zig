//! title: Imports
//! `@import` returns a file as a struct. `pub` controls what other files see.

const std = @import("std");
const expect = std.testing.expect;

// A relative path imports another source file. The result is a struct type.
// The declarations of that type are the `pub` declarations of the file.
const shapes = @import("_shapes.zig");

test "use an imported declaration" {
    try expect(shapes.double(21) == 42);
}

test "imported types work like any other" {
    const c = shapes.Circle{ .radius = 2 };
    try expect(c.area() > 12.5 and c.area() < 12.6);
}

test "a file is a struct" {
    // `@This()` inside a file refers to the implicit struct type of the file.
    // Thus `@import` returns a value that you can use with `.`.
    try expect(@TypeOf(shapes) == type);
    try expect(shapes.pi > 3.14);
}

test "std is just another import" {
    // `@import("std")` uses the same mechanism. The compiler resolves the
    // name itself, and does not use a path.
    try expect(std.mem.eql(u8, "a", "a"));
}
