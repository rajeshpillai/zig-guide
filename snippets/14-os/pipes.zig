//! title: Pipes Are the Child's Streams
//! native
//! A pipe is a descriptor at each end and an end-of-file in the middle.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var args = init.minimal.args.iterate();
    defer args.deinit();
    _ = args.next(); // argv[0]

    // The child half: read standard input to end of file, shout it back.
    if (args.next() != null) {
        var in_buf: [256]u8 = undefined;
        var reader = std.Io.File.stdin().readerStreaming(io, &in_buf);
        var out_buf: [256]u8 = undefined;
        var writer = std.Io.File.stdout().writerStreaming(io, &out_buf);

        while (try reader.interface.takeDelimiter('\n')) |line| {
            var upper: [64]u8 = undefined;
            const shouted = std.ascii.upperString(upper[0..line.len], line);
            try writer.interface.print("{s}\n", .{shouted});
        }
        try writer.interface.flush();
        std.process.exit(0);
    }

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try std.process.executablePath(io, &path_buf);

    var buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &buf);
    const out = &stdout_writer.interface;

    // `.pipe` on a stream means: do not give the child mine, make a new one
    // and hand me the other end as a `File`.
    var child = try std.process.spawn(io, .{
        .argv = &.{ path_buf[0..len], "child" },
        .stdin = .pipe,
        .stdout = .pipe,
    });

    // Both ends are ordinary descriptors, allocated past the three the
    // process started with. Which numbers they got depends on what else this
    // process has open, so the test is that they are new, not that they are 4.
    const fresh = child.stdin.?.handle > 2 and child.stdout.?.handle > 2;
    try out.print("both ends are fresh descriptors: {}\n\n", .{fresh});
    try out.flush();

    var to_child_buf: [256]u8 = undefined;
    var to_child = child.stdin.?.writerStreaming(io, &to_child_buf);
    try to_child.interface.writeAll("one\ntwo\nthree\n");
    try to_child.interface.flush();

    // Closing is the message. The child is blocked in a read that only ends
    // when every write end of that pipe is gone, so a parent that keeps this
    // descriptor open and then waits for output waits forever.
    child.stdin.?.close(io);
    child.stdin = null;

    var from_child_buf: [256]u8 = undefined;
    var from_child = child.stdout.?.readerStreaming(io, &from_child_buf);
    const reply = try from_child.interface.allocRemaining(gpa, .limited(4096));
    defer gpa.free(reply);

    try out.print("{s}", .{reply});
    try out.print("\nterm: {f}\n", .{try child.wait(io)});
    try out.flush();
}
