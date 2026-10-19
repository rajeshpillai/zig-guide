//! title: Everything Is Bytes
//! A type is an agreement about how to read a run of bytes.

const std = @import("std");

const Point = struct { x: u8, y: u8 };

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout_writer.interface;

    // A letter is a number. 'A' is 65, in a form that a person can read
    // more easily.
    const letter: u8 = 'A';
    try out.print("'A' is the number {d}\n\n", .{letter});

    // @sizeOf gives the space that each type uses.
    try out.print("a u8 takes {d} byte\n", .{@sizeOf(u8)});
    try out.print("a u32 takes {d} bytes\n", .{@sizeOf(u32)});
    try out.print("a Point takes {d} bytes\n\n", .{@sizeOf(Point)});

    // std.mem.asBytes gives the bytes of the value.
    const n: u32 = 1;
    try out.writeAll("the u32 1, byte by byte:");
    for (std.mem.asBytes(&n)) |byte| try out.print(" {d}", .{byte});
    try out.writeAll("\n\n");

    // No conversion occurs here. The four bytes do not change. Only the
    // rule for how to read the bytes changes.
    const number: u32 = 0x41424344;
    const letters: [4]u8 = @bitCast(number);
    try out.print("read as a number: {d}\n", .{number});
    try out.writeAll("read as letters:  ");
    for (letters) |c| try out.print("{c}", .{c});
    try out.writeAll("\n");

    try out.flush();
}
