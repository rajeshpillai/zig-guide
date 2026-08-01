//! title: Talking to the Operating System
//! A program is handed streams it did not open, and owes a status back.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &buf);
    const out = &stdout_writer.interface;

    // Three streams were already open when main was entered. Nothing in this
    // program opened them, and the numbers are not arbitrary: every process
    // starts with the same three.
    try out.print("stdin  is descriptor {d}\n", .{std.Io.File.stdin().handle});
    try out.print("stdout is descriptor {d}\n", .{std.Io.File.stdout().handle});
    try out.print("stderr is descriptor {d}\n\n", .{std.Io.File.stderr().handle});

    // They go to different places, which is the whole reason there are two
    // output streams rather than one. This line is the program's result.
    try out.writeAll("this line went to stdout: the program's output\n");
    try out.flush();

    // And this one is for the person watching. Redirect the program into a
    // file and this still appears on the terminal.
    var err_buf: [256]u8 = undefined;
    var err_writer = std.Io.File.stderr().writerStreaming(io, &err_buf);
    try err_writer.interface.writeAll("this line went to stderr: not part of the output\n");
    try err_writer.interface.flush();

    // Returning normally from main is a status of 0, which by convention
    // means success. Returning an error would make it non-zero, and that is
    // the only thing the parent process is guaranteed to learn.
    try out.writeAll("\nreturning from main reports success to whoever ran us\n");
    try out.flush();
}
