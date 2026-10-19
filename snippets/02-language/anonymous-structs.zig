//! title: Anonymous Structs
//! `.{ ... }` infers the type. It also makes tuples.

const std = @import("std");
const expect = std.testing.expect;

fn describe(point: struct { x: i32, y: i32 }) i32 {
    return point.x + point.y;
}

test "anonymous struct literal" {
    // The compiler infers the type from the context. Thus you do not write the name.
    try expect(describe(.{ .x = 1, .y = 2 }) == 3);
}

test "tuples are anonymous structs with numeric fields" {
    const tuple = .{ @as(u8, 1), true, @as(f32, 2.5) };
    try expect(tuple.len == 3);
    try expect(tuple[0] == 1);
    try expect(tuple[1] == true);
    // The name of the field is `1`. `1` is not a valid identifier, thus the
    // field syntax needs `@""`. The two forms read the same field.
    try expect(tuple.@"1" == true);
    try expect(@field(tuple, "2") == 2.5);
}

test "tuples hold mixed types" {
    const pair = .{ @as(u32, 7), "seven" };
    try expect(pair[0] == 7);
    try expect(std.mem.eql(u8, pair[1], "seven"));
}

test "this is how format arguments work" {
    // `.{ a, b }` in a print call is only a tuple. The compiler compares the
    // format string with the tuple at compile time.
    var buf: [32]u8 = undefined;
    const text = try std.mem.print(&buf, "{s}={d}", .{ "x", 42 });
    try expect(std.mem.eql(u8, text, "x=42"));
}
