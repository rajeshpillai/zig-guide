//! title: A queue between two tasks
//! native
//! A producer and a consumer sharing one queue. Built and run for the host: the
//! producer has to make progress while the consumer waits, so this needs
//! `io.concurrent`, which single-threaded wasm cannot provide.

const std = @import("std");

/// Fills the queue and closes it. Capacity is two, so this blocks partway
/// through and resumes as the consumer drains: back pressure, for free.
fn produce(io: std.Io, queue: *std.Io.Queue(u32)) void {
    for (1..6) |i| {
        queue.putOne(io, @intCast(i)) catch return;
    }
    queue.close(io);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var buf: [256]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(io, &buf);
    const out = &file_writer.interface;

    var storage: [2]u32 = undefined;
    var queue: std.Io.Queue(u32) = .init(&storage);

    var producer = try io.concurrent(produce, .{ io, &queue });
    defer producer.await(io);

    // The consumer never asks how many are coming. It reads until the sender
    // closes, which is the whole reason `error.Closed` exists.
    while (queue.getOne(io)) |value| {
        try out.print("got {d}\n", .{value});
    } else |err| {
        try out.print("sender is done: {s}\n", .{@errorName(err)});
    }

    try out.flush();
}
