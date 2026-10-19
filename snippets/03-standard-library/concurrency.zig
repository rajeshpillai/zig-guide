//! title: Concurrency
//! Structured concurrency through the `Io` interface.

const std = @import("std");

fn slowDouble(out: *u32, value: u32) void {
    out.* = value * 2;
}

fn accumulate(total: *u32, mutex: *std.Io.Mutex, io: std.Io, amount: u32) void {
    // `Io.Mutex.lock` takes the io instance, like all other functions that can
    // block. It returns an error for one reason only: a task can cancel it.
    mutex.lock(io) catch return;
    defer mutex.unlock(io);
    total.* += amount;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var buf: [256]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(io, &buf);
    const out = &file_writer.interface;

    // `io.async` starts a task and returns a Future to await.
    var a: u32 = 0;
    var b: u32 = 0;
    var first = io.async(slowDouble, .{ &a, 10 });
    var second = io.async(slowDouble, .{ &b, 20 });
    first.await(io);
    second.await(io);
    try out.print("doubled: {d} {d}\n", .{ a, b });

    // `io.async` can run the task inline. `io.concurrent` cannot: it promises
    // that the caller can continue while the task runs. It fails when the `Io`
    // cannot keep that promise. On this single-threaded wasm target, it fails.
    // This difference is the reason for two functions.
    var c: u32 = 0;
    if (io.concurrent(slowDouble, .{ &c, 30 })) |handle| {
        var pending = handle;
        pending.await(io);
        try out.print("concurrent: {d}\n", .{c});
    } else |err| {
        try out.print("concurrent: {s}\n", .{@errorName(err)});
    }

    // A Group awaits many tasks together. Thus no task continues after the scope.
    var total: u32 = 0;
    var mutex: std.Io.Mutex = .init;
    var group: std.Io.Group = .init;
    for (0..8) |_| {
        group.async(io, accumulate, .{ &total, &mutex, io, 1 });
    }
    try group.await(io);
    try out.print("total: {d}\n", .{total});

    try out.flush();
}
