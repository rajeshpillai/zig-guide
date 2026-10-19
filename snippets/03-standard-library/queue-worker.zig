//! title: A queue between two tasks
//! native
//! A producer and a consumer that share one queue. Built and run for the host.
//! The producer must make progress while the consumer waits. Thus the program
//! needs `io.concurrent`, and single-threaded wasm cannot give it.

const std = @import("std");

/// Fills the queue and closes it. The capacity is two. Thus the function blocks
/// before it is done, and it continues when the consumer removes elements.
/// This is back pressure, and it needs no more code.
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

    // The consumer never asks how many elements will come. It reads until the
    // sender closes the queue. That is the reason for `error.Closed`.
    while (queue.getOne(io)) |value| {
        try out.print("got {d}\n", .{value});
    } else |err| {
        try out.print("sender is done: {s}\n", .{@errorName(err)});
    }

    try out.flush();
}
