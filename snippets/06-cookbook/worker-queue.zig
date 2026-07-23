//! title: A Producer/Consumer Queue
//! native
//! std.Io.Queue is a bounded channel: put blocks when full, get when empty.

const std = @import("std");

const Queue = std.Io.Queue(u64);

fn consumer(q: *Queue, io: std.Io, total: *std.atomic.Value(u64)) void {
    while (true) {
        // Blocks until an item arrives. After close(), remaining items
        // are still delivered; only then does getOne return Closed.
        const job = q.getOne(io) catch return;
        _ = total.fetchAdd(job * job, .monotonic);
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var buf: [256]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(io, &buf);
    const out = &file_writer.interface;

    // The queue borrows its storage; eight slots of backpressure. A
    // producer that runs ahead by more than eight items blocks, which is
    // the mechanism that keeps a fast producer from drowning slow workers.
    var storage: [8]u64 = undefined;
    var queue: Queue = .init(&storage);

    var total = std.atomic.Value(u64).init(0);
    var workers: [3]std.Thread = undefined;
    for (&workers) |*t| {
        t.* = try std.Thread.spawn(.{}, consumer, .{ &queue, io, &total });
    }

    // Produce twenty jobs, then close. Close is the shutdown protocol:
    // no sentinel values, no stop flag, no leaked worker.
    for (1..21) |job| try queue.putAll(io, &.{job});
    queue.close(io);

    for (workers) |t| t.join();
    try out.print("processed total: {d}\n", .{total.load(.monotonic)});

    try out.flush();
}
