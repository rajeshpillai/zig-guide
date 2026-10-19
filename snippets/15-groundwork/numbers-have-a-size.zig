//! title: Numbers Have a Size
//! A u8 counts to 255 and stops. What happens next is a decision you make.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout_writer.interface;

    // The name gives the size. A u8 is an unsigned 8-bit integer. Thus a u8
    // can hold 256 patterns and no more.
    try out.print("u8  counts {d} to {d}\n", .{ std.math.minInt(u8), std.math.maxInt(u8) });
    try out.print("i8  counts {d} to {d}\n", .{ std.math.minInt(i8), std.math.maxInt(i8) });
    try out.print("u32 counts {d} to {d}\n\n", .{ std.math.minInt(u32), std.math.maxInt(u32) });

    const top: u8 = 255;

    // One way past the top: use a different operator that wraps. The answer
    // is 0, and 0 is the answer that you asked for.
    try out.print("255 +% 1 = {d}\n", .{top +% 1});

    // A second way: ask for an answer that can be absent. Then handle the
    // case where the answer is absent.
    if (std.math.add(u8, top, 1)) |sum| {
        try out.print("255 + 1 = {d}\n\n", .{sum});
    } else |err| {
        try out.print("255 + 1 = {t}\n\n", .{err});
    }

    // The size that you select decides the memory for a million values.
    try out.print("a million u8  = {d} bytes\n", .{1_000_000 * @sizeOf(u8)});
    try out.print("a million u32 = {d} bytes\n", .{1_000_000 * @sizeOf(u32)});

    try out.flush();
}
