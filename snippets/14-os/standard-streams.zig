//! title: The Three Standard Streams
//! Buffering belongs to your writer, not to the descriptor underneath it.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    // Two writers, both aimed at descriptor 1. One holds bytes back until it
    // is told to drain; the other has nowhere to hold them.
    var buf: [1024]u8 = undefined;
    var buffered = std.Io.File.stdout().writerStreaming(io, &buf);
    var unbuffered = std.Io.File.stdout().writerStreaming(io, &.{});

    try buffered.interface.writeAll("written first, into a buffer\n");
    try unbuffered.interface.writeAll("written second, straight to the fd\n");
    try buffered.interface.flush();

    const out = &buffered.interface;

    // Whether a stream is a terminal is a question about the descriptor, and
    // it is the question a program asks before deciding to emit colour. Under
    // a WASI sandbox, or a pipe, or a CI log file, the answer is no.
    try out.print("\nstdout is a tty: {}\n", .{try std.Io.File.stdout().isTty(io)});
    try out.print("stderr is a tty: {}\n", .{try std.Io.File.stderr().isTty(io)});

    // Descriptor 2 exists so that a diagnostic survives a redirect of the
    // program's output, and so that it is not sitting in a buffer when the
    // process dies. Progress, warnings and errors go here; results go to 1.
    var err_buf: [256]u8 = undefined;
    var err_writer = std.Io.File.stderr().writerStreaming(io, &err_buf);
    try err_writer.interface.writeAll("this line went to stderr\n");
    try err_writer.interface.flush();

    try out.writeAll("this line went to stdout\n");
    try out.flush();
}
