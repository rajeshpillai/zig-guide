//! title: Anonymous Structs
//! `.{ ... }` infers the type, and gives you tuples for free.

const std = @import("std");
const expect = std.testing.expect;

fn describe(point: struct { x: i32, y: i32 }) i32 {
    return point.x + point.y;
}

test "anonymous struct literal" {
    // The type is inferred from context, so the name need not be written.
    try expect(describe(.{ .x = 1, .y = 2 }) == 3);
}

test "tuples are anonymous structs with numeric fields" {
    const tuple = .{ @as(u8, 1), true, @as(f32, 2.5) };
    try expect(tuple.len == 3);
    try expect(tuple[0] == 1);
    try expect(tuple[1] == true);
}

test "tuples hold mixed types" {
    const pair = .{ @as(u32, 7), "seven" };
    try expect(pair[0] == 7);
    try expect(std.mem.eql(u8, pair[1], "seven"));
}

test "this is how format arguments work" {
    // `.{ a, b }` in a print call is just a tuple; the format string is
    // checked against it at compile time.
    var buf: [32]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "{s}={d}", .{ "x", 42 });
    try expect(std.mem.eql(u8, text, "x=42"));
}
