//! title: Queues
//! `Io.Queue` is a bounded channel. It has a fixed capacity, the two ends can
//! block, and the receiver can see a close.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var buf: [256]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(io, &buf);
    const out = &file_writer.interface;

    // The queue owns no memory. The capacity is the buffer that you give it.
    var storage: [4]u32 = undefined;
    var queue: std.Io.Queue(u32) = .init(&storage);

    // `put` blocks when the queue is full, unless you ask for a minimum of
    // zero. Then it takes the elements that fit and returns their count.
    const accepted = try queue.put(io, &.{ 1, 2, 3, 4, 5, 6 }, 0);
    try out.print("accepted {d} of 6\n", .{accepted});

    // A close tells the receiver that no more elements will come. The queue
    // still delivers the elements in the buffer before it tells the receiver.
    queue.close(io);

    var total: u32 = 0;
    while (queue.getOne(io)) |value| {
        total += value;
    } else |err| {
        try out.print("drained {d}, then {s}\n", .{ total, @errorName(err) });
    }

    // A closed queue refuses new elements, also when the buffer is empty.
    queue.putOne(io, 7) catch |err| {
        try out.print("put after close: {s}\n", .{@errorName(err)});
    };

    try out.flush();
}
