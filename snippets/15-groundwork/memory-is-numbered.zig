//! title: Memory Is Numbered
//! An address is a number. Values next to each other are @sizeOf(T) apart.
//!
//! This snippet has no `.expected` file, on purpose. The program prints real
//! addresses, and the chapter is about them. The addresses move when the
//! compiler changes the layout of the module. If a file fixed the addresses,
//! a normal toolchain update would make the nightly fail, and the failure
//! would teach nothing. The chapter makes a claim about the gaps between the
//! addresses, and the reader checks the gaps on the page.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout_writer.interface;

    var row = [_]u32{ 10, 20, 30, 40 };

    // @intFromPtr does no work. It shows the address as the number that it is.
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

    // A pointer holds one of these numbers and nothing else.
    const p: *u32 = &row[2];
    try out.print("a *u32 is {d} bytes wide\n", .{@sizeOf(*u32)});
    try out.print("this one holds {d}\n", .{@intFromPtr(p)});
    try out.print("reading through it gives {d}\n\n", .{p.*});

    // A write through the pointer changes that box in the row, not a copy.
    p.* = 99;
    try out.print("after p.* = 99, row[2] = {d}\n", .{row[2]});

    try out.flush();
}
