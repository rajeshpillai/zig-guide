//! title: Memory Is Numbered
//! An address is a number, and neighbouring values sit @sizeOf(T) apart.
//!
//! Deliberately no `.expected` file. This prints real addresses, which is the
//! point of the chapter, and they move whenever the compiler changes the
//! layout of the module. Pinning them would turn a routine toolchain bump into
//! a red nightly that teaches nobody anything. The gaps between them are the
//! claim the chapter makes, and those are checked by the reader on the page.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout_writer.interface;

    var row = [_]u32{ 10, 20, 30, 40 };

    // @intFromPtr does no work. It shows the number the address already was.
    const first = @intFromPtr(&row[0]);
    try out.print("row[0] sits at address {d}\n\n", .{first});

    for (&row, 0..) |*slot, i| {
        const here = @intFromPtr(slot);
        try out.print(
            "row[{d}] = {d}, {d} bytes along from row[0]\n",
            .{ i, slot.*, here - first },
        );
    }
    try out.print("\n@sizeOf(u32) = {d}\n\n", .{@sizeOf(u32)});

    // A pointer holds one of those numbers and nothing else.
    const p: *u32 = &row[2];
    try out.print("a *u32 is {d} bytes wide\n", .{@sizeOf(*u32)});
    try out.print("this one holds {d}\n", .{@intFromPtr(p)});
    try out.print("reading through it gives {d}\n\n", .{p.*});

    // Writing through it writes that box in the row, not a copy of it.
    p.* = 99;
    try out.print("after p.* = 99, row[2] = {d}\n", .{row[2]});

    try out.flush();
}
