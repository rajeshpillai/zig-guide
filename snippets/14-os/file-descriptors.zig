//! title: A File Descriptor Is a Number
//! Each thing that the OS gives you to read or write is an integer. Here are three.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &buf);
    const out = &stdout_writer.interface;

    // A `std.Io.File` is a handle and one flag bit. The handle is the number.
    // Its type is the descriptor type of the platform.
    try out.print("File.Handle = {s}\n", .{@typeName(std.Io.File.Handle)});
    try out.print("a File is {d} bytes\n\n", .{@sizeOf(std.Io.File)});

    // Each process starts with these three. No code opened them. They were
    // already open when main started.
    try out.print("stdin  {d}\n", .{std.Io.File.stdin().handle});
    try out.print("stdout {d}\n", .{std.Io.File.stdout().handle});
    try out.print("stderr {d}\n\n", .{std.Io.File.stderr().handle});
    try out.flush();

    // The File that `stdout()` returns is not special. Build a File from the
    // number 1, and the File writes to the same stream.
    const by_hand: std.Io.File = .{ .handle = 1, .flags = .{ .nonblocking = false } };
    var hand_buf: [64]u8 = undefined;
    var hand_writer = by_hand.writerStreaming(io, &hand_buf);
    try hand_writer.interface.writeAll("written through a hand-built File\n");
    try hand_writer.interface.flush();

    try out.print("same handle: {}\n", .{by_hand.handle == std.Io.File.stdout().handle});
    try out.flush();
}
