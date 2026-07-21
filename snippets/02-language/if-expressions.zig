//! title: If Expressions
//! `if` takes a `bool` — there is no truthiness in Zig.

const std = @import("std");
const expect = std.testing.expect;

test "if as a statement" {
    const a = true;
    var x: u16 = 0;
    if (a) {
        x += 1;
    } else {
        x += 2;
    }
    try expect(x == 1);
}

test "if as an expression" {
    const a = true;
    // The ternary equivalent; both branches must yield the same type.
    const x: u16 = if (a) 1 else 2;
    try expect(x == 1);
}

test "if unwraps an optional" {
    const maybe: ?u8 = 42;
    const doubled: u16 = if (maybe) |value| value * 2 else 0;
    try expect(doubled == 84);
}
