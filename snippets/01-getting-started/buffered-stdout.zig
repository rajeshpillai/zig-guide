//! title: Buffered Stdout
//! Since 0.15 ("writergate") writers are buffered and you must `flush`.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    try out.print("{s} v{d}.{d}\n", .{ "zig", 0, 16 });
    for (0..3) |i| try out.print("  line {d}\n", .{i});

    // Nothing is written until the buffer is drained.
    try out.flush();
}
