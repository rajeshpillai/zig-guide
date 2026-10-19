//! title: Strings Are Bytes
//! Zig has no string type. A literal is bytes, with a zero at the end.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout_writer.interface;

    const greeting = "hello";

    // The type shows all that the memory stores: a pointer to five bytes, and
    // a zero after them. The length does not count the zero.
    try out.print("\"hello\" is a {s}\n", .{@typeName(@TypeOf(greeting))});
    try out.print("greeting.len       = {d}\n", .{greeting.len});
    try out.print("the array occupies = {d} bytes\n\n", .{@sizeOf(@TypeOf(greeting.*))});

    // An index gives a number, because the memory stores only a number.
    try out.print("greeting[0] = {d}, which prints as '{c}'\n\n", .{ greeting[0], greeting[0] });

    // Two separate literals with the same contents. Zig does not allow `==`
    // on slices. std.mem.eql compares the contents.
    const a: []const u8 = "cat";
    const b: []const u8 = "cat";
    try out.print("std.mem.eql(a, b) = {}\n\n", .{std.mem.eql(u8, a, b)});

    // A length in bytes is not a count of characters. On this string, you can
    // see the difference.
    const word = "héllo";
    try out.print("\"héllo\".len = {d} bytes\n", .{word.len});
    try out.print("codepoints  = {d}\n", .{try std.unicode.utf8CountCodepoints(word)});

    try out.flush();
}
