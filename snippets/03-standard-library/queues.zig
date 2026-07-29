//! title: Queues
//! `Io.Queue` is a bounded channel: fixed capacity, blocking ends, and a close
//! that the receiving side can see.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var buf: [256]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(io, &buf);
    const out = &file_writer.interface;

    // The queue owns no memory. Capacity is the buffer you hand it.
    var storage: [4]u32 = undefined;
    var queue: std.Io.Queue(u32) = .init(&storage);

    // `put` blocks when the queue is full, unless you ask for a minimum of
    // zero: then it takes what fits and tells you how much that was.
    const accepted = try queue.put(io, &.{ 1, 2, 3, 4, 5, 6 }, 0);
    try out.print("accepted {d} of 6\n", .{accepted});

    // Closing says there will be no more. Anything already buffered is still
    // delivered before the receiver is told.
    queue.close(io);

    var total: u32 = 0;
    while (queue.getOne(io)) |value| {
        total += value;
    } else |err| {
        try out.print("drained {d}, then {s}\n", .{ total, @errorName(err) });
    }

    // A closed queue refuses new elements even though the buffer is empty now.
    queue.putOne(io, 7) catch |err| {
        try out.print("put after close: {s}\n", .{@errorName(err)});
    };

    try out.flush();
}
