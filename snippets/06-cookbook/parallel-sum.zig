//! title: Splitting Work Across Threads
//! native
//! One chunk per thread, one result slot per thread, zero locks.

const std = @import("std");

// Each worker owns its chunk and its slot outright. Nothing is shared,
// so there is nothing to synchronize until the join.
fn sumChunk(chunk: []const u64, slot: *u64) void {
    var sum: u64 = 0;
    for (chunk) |x| sum += x;
    slot.* = sum;
}

pub fn main(init: std.process.Init) !void {
    var buf: [256]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    var numbers: [1000]u64 = undefined;
    for (&numbers, 1..) |*n, i| n.* = i;

    // Fixed worker count keeps this demo deterministic to read; a real
    // program would start from std.Thread.getCpuCount().
    const workers = 4;
    var slots: [workers]u64 = undefined;
    var threads: [workers]std.Thread = undefined;

    // Ceiling division so the last chunk picks up the remainder.
    const chunk_size = (numbers.len + workers - 1) / workers;
    for (&threads, &slots, 0..) |*t, *slot, w| {
        const start = w * chunk_size;
        const end = @min(start + chunk_size, numbers.len);
        t.* = try std.Thread.spawn(.{}, sumChunk, .{ numbers[start..end], slot });
    }

    // join is the synchronization: after it returns, that thread's writes
    // are visible here.
    for (threads) |t| t.join();

    var total: u64 = 0;
    for (slots) |s| total += s;
    try out.print("total: {d}\n", .{total});
    try out.print("check: {d}\n", .{@as(u64, 1000 * 1001 / 2)});

    try out.flush();
}
