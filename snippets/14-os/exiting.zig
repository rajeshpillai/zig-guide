//! title: Exiting
//! `exit` stops the process. It does not return from your program.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout_writer.interface;

    // The program registers these now. The exit below skips each of them.
    defer std.debug.print("this defer never runs\n", .{});
    defer out.flush() catch {};

    try out.writeAll("first line, flushed by hand\n");
    try out.flush();

    try out.writeAll("second line, still sitting in the buffer\n");

    // The process stops here. This is not a return. No defer runs, and the
    // program flushes no buffer. Thus the program loses the second line above, and
    // it loses the memory that held the line.
    std.process.exit(0);
}
