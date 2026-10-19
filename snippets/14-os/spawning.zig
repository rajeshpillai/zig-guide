//! title: Spawn a Process
//! native
//! A child is a program, an argument list, and a status code for the parent.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    var args = init.minimal.args.iterate();
    defer args.deinit();
    _ = args.next(); // argv[0]

    // With an argument, this program is the child. The program runs itself.
    // Thus it does not need a system binary to be installed.
    if (args.next()) |mode| {
        if (std.mem.eql(u8, mode, "ok")) {
            var buf: [64]u8 = undefined;
            var w = std.Io.File.stdout().writerStreaming(io, &buf);
            try w.interface.writeAll("hello from the child\n");
            try w.interface.flush();
            std.process.exit(0);
        }
        // A program reports failure with a number, and only a number. If there
        // is a reason, the program writes the reason to stderr.
        std.process.exit(3);
    }

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const len = try std.process.executablePath(io, &path_buf);
    const self = path_buf[0..len];

    var buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &buf);
    const out = &stdout_writer.interface;

    // `run` spawns, collects both streams to the end, and waits. Use it when
    // the output is small and you want all of the output.
    const ok = try std.process.run(gpa, io, .{ .argv = &.{ self, "ok" } });
    defer gpa.free(ok.stdout);
    defer gpa.free(ok.stderr);
    try out.print("child stdout: {s}", .{ok.stdout});
    try out.print("child term:   {f}\n\n", .{ok.term});

    const failed = try std.process.run(gpa, io, .{ .argv = &.{ self, "fail" } });
    defer gpa.free(failed.stdout);
    defer gpa.free(failed.stderr);
    try out.print("failing child: {f}\n", .{failed.term});
    try out.print("succeeded:     {}\n", .{failed.term.success()});

    // A status is a `u8`. Thus there are only 256 values, and only 0 means
    // success. The program decides the meaning of the other values.
    switch (failed.term) {
        .exited => |code| try out.print("exit code:     {d}\n", .{code}),
        else => try out.print("killed or stopped rather than exited\n", .{}),
    }

    try out.flush();
}
