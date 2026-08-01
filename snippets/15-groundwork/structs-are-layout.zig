//! title: Structs Are Layout
//! Fields sit next to each other, and the machine has opinions about where.

const std = @import("std");

// `extern` means C's layout: fields in the order written, padded so each one
// starts at an address the machine likes. That is the layout to understand
// first, because it is the one another language or a file format agrees to.
const Row = extern struct {
    flag: u8,
    count: u32,
    tag: u8,
};

// The same three fields, largest first.
const Packed = extern struct {
    count: u32,
    flag: u8,
    tag: u8,
};

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout_writer.interface;

    try out.print("the fields hold {d} bytes of data\n", .{@sizeOf(u8) + @sizeOf(u32) + @sizeOf(u8)});
    try out.print("but @sizeOf(Row) = {d}\n\n", .{@sizeOf(Row)});

    // Where each field actually starts. The gaps are the padding.
    try out.print("flag  starts at byte {d}\n", .{@offsetOf(Row, "flag")});
    try out.print("count starts at byte {d}\n", .{@offsetOf(Row, "count")});
    try out.print("tag   starts at byte {d}\n\n", .{@offsetOf(Row, "tag")});

    // Nothing changed except the order they were written in.
    try out.print("same fields, largest first: {d} bytes\n", .{@sizeOf(Packed)});

    // And what Zig does when you do not ask for C's layout: it is free to
    // arrange the fields however it likes, which is usually the small one.
    const Auto = struct { flag: u8, count: u32, tag: u8 };
    try out.print("Zig's own layout for them:  {d} bytes\n", .{@sizeOf(Auto)});

    try out.flush();
}
