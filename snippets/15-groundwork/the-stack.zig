//! title: The Stack
//! Locals get an address when a call starts, and lose it when the call returns.
//!
//! The program prints comparisons, not the addresses. The frame layout of the
//! compiler decides the addresses, and they move when the toolchain changes.
//! The chapter teaches claims about the addresses (each call gets its own
//! place, and a second call uses the same place again). These claims are true
//! for all values of the numbers.

const std = @import("std");

var main_local: usize = 0;
var outer_local: usize = 0;
var inner_local: usize = 0;
var outer_local_again: usize = 0;

fn inner() void {
    var value: u32 = 3;
    _ = &value; // keep the value in memory, not in a register
    inner_local = @intFromPtr(&value);
}

fn outer(record: *usize) void {
    var value: u32 = 2;
    _ = &value;
    record.* = @intFromPtr(&value);
    inner();
}

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout_writer.interface;

    var value: u32 = 1;
    _ = &value;
    main_local = @intFromPtr(&value);

    outer(&outer_local);

    // Each call gets its own region for its local variables. Three calls are
    // live at the same time here, and no two of them share a place.
    try out.print("main and outer used different addresses:  {}\n", .{main_local != outer_local});
    try out.print("outer and inner used different addresses: {}\n", .{inner_local != outer_local});

    // The direction of the regions depends on the target. The language has
    // no rule for the direction. Most machines count downward. This machine
    // does not, and nothing in the chapter depends on the answer.
    try out.print("deeper calls got higher addresses here:   {}\n", .{inner_local > main_local});

    // outer() returned, thus its region is free again.
    outer(&outer_local_again);
    try out.print("\nthe second call to outer reused the same address: {}\n", .{outer_local == outer_local_again});

    try out.print("\nso a pointer to outer's local, kept after it returned,\n", .{});
    try out.print("would now be pointing at the second call's data.\n", .{});

    try out.flush();
}
