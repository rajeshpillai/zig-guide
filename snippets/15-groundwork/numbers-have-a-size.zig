//! title: Numbers Have a Size
//! A u8 counts to 255 and stops. What happens next is a decision you make.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout_writer.interface;

    // The size is written into the name. A u8 is an unsigned 8-bit integer,
    // so there are 256 patterns it can hold and no more.
    try out.print("u8  counts {d} to {d}\n", .{ std.math.minInt(u8), std.math.maxInt(u8) });
    try out.print("i8  counts {d} to {d}\n", .{ std.math.minInt(i8), std.math.maxInt(i8) });
    try out.print("u32 counts {d} to {d}\n\n", .{ std.math.minInt(u32), std.math.maxInt(u32) });

    const top: u8 = 255;

    // One way past the top: ask to wrap, with a different operator. The answer
    // is 0, and it is the answer you asked for.
    try out.print("255 +% 1 = {d}\n", .{top +% 1});

    // Another way: ask for an answer that might not exist, and handle the case
    // where it does not.
    if (std.math.add(u8, top, 1)) |sum| {
        try out.print("255 + 1 = {d}\n\n", .{sum});
    } else |err| {
        try out.print("255 + 1 = {t}\n\n", .{err});
    }

    // Choosing a size is choosing how much memory a million of them cost.
    try out.print("a million u8  = {d} bytes\n", .{1_000_000 * @sizeOf(u8)});
    try out.print("a million u32 = {d} bytes\n", .{1_000_000 * @sizeOf(u32)});

    try out.flush();
}
