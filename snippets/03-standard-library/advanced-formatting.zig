//! title: Advanced Formatting
//! Custom `format` methods, and the specifiers that changed in 0.15.

const std = @import("std");
const expect = std.testing.expect;

const Point = struct {
    x: i32,
    y: i32,

    // The `{f}` specifier uses a `format` method that takes a
    // `*std.Io.Writer`. Older Zig also gave a fmt string and options to the
    // method. That signature no longer applies.
    pub fn format(self: Point, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.print("({d}, {d})", .{ self.x, self.y });
    }
};

const Colour = enum { red, green, blue };

test "{f} calls a custom format method" {
    var buf: [64]u8 = undefined;
    const text = try std.mem.print(&buf, "{f}", .{Point{ .x = 1, .y = 2 }});
    try expect(std.mem.eql(u8, text, "(1, 2)"));
}

test "{t} prints an enum tag name" {
    var buf: [64]u8 = undefined;
    const text = try std.mem.print(&buf, "{t}", .{Colour.green});
    try expect(std.mem.eql(u8, text, "green"));
}

test "{any} falls back to a structural dump" {
    var buf: [128]u8 = undefined;
    const text = try std.mem.print(&buf, "{any}", .{[_]u8{ 1, 2, 3 }});
    // The exact text can change, but the text contains the elements.
    try expect(std.mem.find(u8, text, "1") != null);
}

test "format strings are checked at compile time" {
    // The wrong number of arguments is a compile error, not a runtime
    // error. A specifier that the type does not support is also a compile
    // error.
    var buf: [32]u8 = undefined;
    const ok = try std.mem.print(&buf, "{d} {s}", .{ 1, "two" });
    try expect(std.mem.eql(u8, ok, "1 two"));
}

test "writing to a list" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    try out.writer.print("{f}", .{Point{ .x = 3, .y = 4 }});
    try expect(std.mem.eql(u8, out.written(), "(3, 4)"));
}
