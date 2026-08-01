//! title: Strings Are Bytes
//! There is no string type. A literal is bytes, with a zero on the end.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout_writer.interface;

    const greeting = "hello";

    // The type is the whole story: a pointer to five bytes, with a zero after
    // them that the length does not count.
    try out.print("\"hello\" is a {s}\n", .{@typeName(@TypeOf(greeting))});
    try out.print("greeting.len       = {d}\n", .{greeting.len});
    try out.print("the array occupies = {d} bytes\n\n", .{@sizeOf(@TypeOf(greeting.*))});

    // Indexing gives a number, because that is all that is stored.
    try out.print("greeting[0] = {d}, which prints as '{c}'\n\n", .{ greeting[0], greeting[0] });

    // Two separate literals with the same contents. `==` on slices compares
    // where they point, which is not the question you meant to ask.
    const a: []const u8 = "cat";
    const b: []const u8 = "cat";
    try out.print("std.mem.eql(a, b) = {}\n\n", .{std.mem.eql(u8, a, b)});

    // A length in bytes is not a count of characters, and on this string the
    // difference is visible.
    const word = "héllo";
    try out.print("\"héllo\".len = {d} bytes\n", .{word.len});
    try out.print("codepoints  = {d}\n", .{try std.unicode.utf8CountCodepoints(word)});

    try out.flush();
}
