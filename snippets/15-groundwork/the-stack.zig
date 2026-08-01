//! title: The Stack
//! Locals get an address when a call starts, and lose it when the call returns.
//!
//! Prints comparisons rather than the addresses themselves. The addresses are
//! decided by the compiler's frame layout and move on a toolchain bump; the
//! claims about them (deeper is lower, a second call reuses the same spot) are
//! what the chapter teaches and they hold whatever the numbers are.

const std = @import("std");

var main_local: usize = 0;
var outer_local: usize = 0;
var inner_local: usize = 0;
var outer_local_again: usize = 0;

fn inner() void {
    var value: u32 = 3;
    _ = &value; // keep it in memory rather than a register
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

    // Each call gets its own region for its locals. Three calls are live at
    // once here, and no two of them share a spot.
    try out.print("main and outer used different addresses:  {}\n", .{main_local != outer_local});
    try out.print("outer and inner used different addresses: {}\n", .{inner_local != outer_local});

    // Which direction the regions run is the target's business, not a rule of
    // the language. Most machines you will meet count downward; this one does
    // not, and nothing in the chapter depends on the answer.
    try out.print("deeper calls got higher addresses here:   {}\n", .{inner_local > main_local});

    // outer() has returned, so the region it was using is no longer spoken for.
    outer(&outer_local_again);
    try out.print("\nthe second call to outer reused the same address: {}\n", .{outer_local == outer_local_again});

    try out.print("\nso a pointer to outer's local, kept after it returned,\n", .{});
    try out.print("would now be pointing at the second call's data.\n", .{});

    try out.flush();
}
