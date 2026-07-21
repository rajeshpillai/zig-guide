//! title: Concurrency
//! Structured concurrency through the `Io` interface.

const std = @import("std");

fn slowDouble(out: *u32, value: u32) void {
    out.* = value * 2;
}

fn accumulate(total: *u32, mutex: *std.Io.Mutex, io: std.Io, amount: u32) void {
    // `Io.Mutex.lock` takes the io instance, like everything else that can
    // block. It returns an error only because it can be cancelled.
    mutex.lock(io) catch return;
    defer mutex.unlock(io);
    total.* += amount;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var buf: [256]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(io, &buf);
    const out = &file_writer.interface;

    // `io.async` starts a task and hands back a Future to await.
    var a: u32 = 0;
    var b: u32 = 0;
    var first = io.async(slowDouble, .{ &a, 10 });
    var second = io.async(slowDouble, .{ &b, 20 });
    first.await(io);
    second.await(io);
    try out.print("doubled: {d} {d}\n", .{ a, b });

    // A Group awaits many tasks at once, so nothing outlives the scope.
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
