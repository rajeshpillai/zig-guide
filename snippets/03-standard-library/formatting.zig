//! title: Formatting
//! Compile-time checked format strings.

const std = @import("std");
const expect = std.testing.expect;

test "bufPrint formats into memory you own" {
    var buf: [64]u8 = undefined;
    const text = try std.mem.print(&buf, "{s} is {d}", .{ "answer", 42 });
    try expect(std.mem.eql(u8, text, "answer is 42"));
}

test "common specifiers" {
    var buf: [64]u8 = undefined;

    try expect(std.mem.eql(u8, try std.mem.print(&buf, "{d}", .{255}), "255"));
    try expect(std.mem.eql(u8, try std.mem.print(&buf, "{x}", .{255}), "ff"));
    try expect(std.mem.eql(u8, try std.mem.print(&buf, "{X}", .{255}), "FF"));
    try expect(std.mem.eql(u8, try std.mem.print(&buf, "{b}", .{5}), "101"));
    try expect(std.mem.eql(u8, try std.mem.print(&buf, "{o}", .{8}), "10"));
    try expect(std.mem.eql(u8, try std.mem.print(&buf, "{c}", .{@as(u8, 'A')}), "A"));
}

test "width, alignment and fill" {
    var buf: [64]u8 = undefined;

    // {[fill][align][width]}: align is <, ^ or >.
    try expect(std.mem.eql(u8, try std.mem.print(&buf, "{d:5}", .{42}), "   42"));
    try expect(std.mem.eql(u8, try std.mem.print(&buf, "{d:<5}", .{42}), "42   "));
    try expect(std.mem.eql(u8, try std.mem.print(&buf, "{d:^5}", .{42}), " 42  "));
    try expect(std.mem.eql(u8, try std.mem.print(&buf, "{d:0>5}", .{42}), "00042"));
}

test "a width makes a signed integer carry its sign" {
    var buf: [64]u8 = undefined;

    // The same width against three types. A literal is `comptime_int` and
    // prints bare, which is what the tests above are quietly relying on.
    try expect(std.mem.eql(u8, try std.mem.print(&buf, "{d:5}", .{42}), "   42"));

    // A signed value prints a leading `+` once a width is given. The sign
    // belongs to the number, so the fill goes in front of it rather than
    // between the sign and the digits.
    const signed: i32 = 42;
    try expect(std.mem.eql(u8, try std.mem.print(&buf, "{d:5}", .{signed}), "  +42"));
    try expect(std.mem.eql(u8, try std.mem.print(&buf, "{d:<5}", .{signed}), "+42  "));
    try expect(std.mem.eql(u8, try std.mem.print(&buf, "{d:0>5}", .{signed}), "00+42"));

    // An unsigned value has no sign to print, so a width pads as expected.
    const unsigned: u32 = 42;
    try expect(std.mem.eql(u8, try std.mem.print(&buf, "{d:5}", .{unsigned}), "   42"));

    // Drop the width and the `+` goes away, which is why this is easy to
    // miss until a column of numbers is being lined up.
    try expect(std.mem.eql(u8, try std.mem.print(&buf, "{d}", .{signed}), "42"));
}

test "float precision" {
    var buf: [64]u8 = undefined;
    try expect(std.mem.eql(u8, try std.mem.print(&buf, "{d:.2}", .{3.14159}), "3.14"));
}

test "escaping braces" {
    var buf: [64]u8 = undefined;
    try expect(std.mem.eql(u8, try std.mem.print(&buf, "{{{d}}}", .{1}), "{1}"));
}

test "allocPrint when the length is unknown" {
    const gpa = std.testing.allocator;
    const text = try gpa.print("{d}-{d}", .{ 1, 2 });
    defer gpa.free(text);
    try expect(std.mem.eql(u8, text, "1-2"));
}
