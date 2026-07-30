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

    // The process stops here. Not a return: no defer runs, no buffer is
    // drained, and the second line above is lost with the memory holding it.
    std.process.exit(0);
}
