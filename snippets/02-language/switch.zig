//! title: Switch
//! Exhaustive by construction: a missed case is a compile error.

const std = @import("std");
const expect = std.testing.expect;

test "switch as a statement" {
    var x: i8 = 10;
    switch (x) {
        -1...1 => x = -x, // inclusive ranges
        10, 100 => x = @divExact(x, 10), // multiple values
        else => {},
    }
    try expect(x == 1);
}

test "switch as an expression" {
    const x: i8 = 10;
    const y: i8 = switch (x) {
        -1...1 => -x,
        10, 100 => @divExact(x, 10),
        else => 0,
    };
    try expect(y == 1);
}

const Direction = enum { north, south, east, west };

fn isVertical(d: Direction) bool {
    // No `else` branch: the compiler proves every case is handled, so adding
    // a new enum tag later turns this into a compile error rather than a bug.
    return switch (d) {
        .north, .south => true,
        .east, .west => false,
    };
}

test "exhaustive switch over an enum" {
    try expect(isVertical(.north));
    try expect(!isVertical(.east));
}
