//! title: An Atomic Work Index
//! native
//! When chunks are not equal, let each thread get the next job itself.

const std = @import("std");

const jobs = blk: {
    var j: [100]u64 = undefined;
    for (&j, 1..) |*x, i| x.* = i;
    break :blk j;
};

fn worker(next: *std.atomic.Value(usize), total: *std.atomic.Value(u64)) void {
    while (true) {
        // fetchAdd gives each index exactly one time, with no lock. Two threads
        // can race here, but they never get the same job.
        const i = next.fetchAdd(1, .monotonic);
        if (i >= jobs.len) return;

        const result = jobs[i] * jobs[i]; // the "work"
        _ = total.fetchAdd(result, .monotonic);
    }
}

pub fn main(init: std.process.Init) !void {
    var buf: [256]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    var next = std.atomic.Value(usize).init(0);
    var total = std.atomic.Value(u64).init(0);

    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, worker, .{ &next, &total });
    }
    for (threads) |t| t.join();

    // The threads completed in a random order. But each job ran exactly one
    // time. Thus the sum is the same on each run.
    try out.print("sum of squares 1..100: {d}\n", .{total.load(.monotonic)});

    try out.flush();
}
