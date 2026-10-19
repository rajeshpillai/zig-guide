//! title: The Three Standard Streams
//! The buffer belongs to your writer, not to the descriptor under the writer.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    // Two writers, both for descriptor 1. One holds bytes until the program
    // flushes it. The other has no buffer, so it writes the bytes at once.
    var buf: [1024]u8 = undefined;
    var buffered = std.Io.File.stdout().writerStreaming(io, &buf);
    var unbuffered = std.Io.File.stdout().writerStreaming(io, &.{});

    try buffered.interface.writeAll("written first, into a buffer\n");
    try unbuffered.interface.writeAll("written second, straight to the fd\n");
    try buffered.interface.flush();

    const out = &buffered.interface;

    // "Is the stream a terminal?" is a question about the descriptor. A
    // program asks it before it decides to write colour. Through a pipe, or
    // into a CI log file, the answer is no. The browser runner says yes.
    try out.print("\nstdout is a tty: {}\n", .{try std.Io.File.stdout().isTty(io)});
    try out.print("stderr is a tty: {}\n", .{try std.Io.File.stderr().isTty(io)});

    // Descriptor 2 exists for two reasons. A diagnostic stays visible when you
    // redirect the output of the program. Also, the diagnostic is not in a
    // buffer when the process stops. Progress, warnings and errors go here.
    // Results go to 1.
    var err_buf: [256]u8 = undefined;
    var err_writer = std.Io.File.stderr().writerStreaming(io, &err_buf);
    try err_writer.interface.writeAll("this line went to stderr\n");
    try err_writer.interface.flush();

    try out.writeAll("this line went to stdout\n");
    try out.flush();
}
