//! title: Exiting
//! `exit` is the process stopping, not your program returning.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout_writer.interface;

    // Registered now, and every one of them is skipped below.
    defer std.debug.print("this defer never runs\n", .{});
    defer out.flush() catch {};

    try out.writeAll("first line, flushed by hand\n");
    try out.flush();

    try out.writeAll("second line, still sitting in the buffer\n");

    // The process stops here. This is not a return. No defer runs and no
    // buffer is drained, so the second line above is lost along with the
    // memory that held it.
    std.process.exit(0);
}
