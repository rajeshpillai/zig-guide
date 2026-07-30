//! title: A File Descriptor Is a Number
//! Everything the OS hands you to read or write is an integer. Here are three.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &buf);
    const out = &stdout_writer.interface;

    // A `std.Io.File` is a handle and two flag bits. The handle is the number,
    // and its type is whatever the platform calls a descriptor.
    try out.print("File.Handle = {s}\n", .{@typeName(std.Io.File.Handle)});
    try out.print("a File is {d} bytes\n\n", .{@sizeOf(std.Io.File)});

    // The three every process starts with. Nothing opened them; they were
    // already there when main was entered.
    try out.print("stdin  {d}\n", .{std.Io.File.stdin().handle});
    try out.print("stdout {d}\n", .{std.Io.File.stdout().handle});
    try out.print("stderr {d}\n\n", .{std.Io.File.stderr().handle});
    try out.flush();

    // Nothing is special about the File that `stdout()` returns. Build one out
    // of the number 1 and it addresses the same stream.
    const by_hand: std.Io.File = .{ .handle = 1, .flags = .{ .nonblocking = false } };
    var hand_buf: [64]u8 = undefined;
    var hand_writer = by_hand.writerStreaming(io, &hand_buf);
    try hand_writer.interface.writeAll("written through a hand-built File\n");
    try hand_writer.interface.flush();

    try out.print("same handle: {}\n", .{by_hand.handle == std.Io.File.stdout().handle});
    try out.flush();
}
