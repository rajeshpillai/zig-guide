//! title: Talk to the Operating System
//! A program gets streams that it did not open, and must return a status.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &buf);
    const out = &stdout_writer.interface;

    // Three streams were already open when main started. Nothing in this
    // program opened them, and the numbers are not random: each process starts
    // with the same three.
    try out.print("stdin  is descriptor {d}\n", .{std.Io.File.stdin().handle});
    try out.print("stdout is descriptor {d}\n", .{std.Io.File.stdout().handle});
    try out.print("stderr is descriptor {d}\n\n", .{std.Io.File.stderr().handle});

    // The streams go to different places. For this reason, there are two
    // output streams. This line is the result of the program.
    try out.writeAll("this line went to stdout: the program's output\n");
    try out.flush();

    // This line is for the person who watches. If you redirect the program
    // into a file, this line still shows on the terminal.
    var err_buf: [256]u8 = undefined;
    var err_writer = std.Io.File.stderr().writerStreaming(io, &err_buf);
    try err_writer.interface.writeAll("this line went to stderr: not part of the output\n");
    try err_writer.interface.flush();

    // A normal return from main gives a status of 0. By convention, 0 means
    // success. An error return makes the status non-zero. The operating system
    // guarantees only the status to the parent process.
    try out.writeAll("\nreturning from main reports success to whoever ran us\n");
    try out.flush();
}
