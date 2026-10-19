//! title: Structs Are Layout
//! Fields are next to each other, and the machine has a preferred place for each.

const std = @import("std");

// `extern` gives the layout of C: the fields are in the order of the source.
// Padding makes each field start at an address that the machine prefers for
// its type. Learn this layout first, because other languages and file formats
// use it.
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

    // The start of each field. The gaps are the padding.
    try out.print("flag  starts at byte {d}\n", .{@offsetOf(Row, "flag")});
    try out.print("count starts at byte {d}\n", .{@offsetOf(Row, "count")});
    try out.print("tag   starts at byte {d}\n\n", .{@offsetOf(Row, "tag")});

    // Only the order of the fields changed.
    try out.print("same fields, largest first: {d} bytes\n", .{@sizeOf(Packed)});

    // Without `extern`, Zig can put the fields in any order. Zig usually
    // selects the smaller layout.
    const Auto = struct { flag: u8, count: u32, tag: u8 };
    try out.print("Zig's own layout for them:  {d} bytes\n", .{@sizeOf(Auto)});

    try out.flush();
}
