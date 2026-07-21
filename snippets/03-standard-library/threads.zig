//! title: Threads
//! native
//! Real OS threads. Built and run for the host: wasm32-wasi is single-threaded,
//! so `std.Thread.spawn` does not even compile for it.

const std = @import("std");

fn addTo(total: *u32, amount: u32) void {
    total.* += amount;
}

fn addLocked(total: *u32, mutex: *std.Io.Mutex, io: std.Io, amount: u32) void {
    mutex.lock(io) catch return;
    defer mutex.unlock(io);
    total.* += amount;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var buf: [256]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(io, &buf);
    const out = &file_writer.interface;

    // One thread, joined explicitly.
    var value: u32 = 0;
    const thread = try std.Thread.spawn(.{}, addTo, .{ &value, 42 });
    thread.join();
    try out.print("single: {d}\n", .{value});

    // Many threads touching one variable need synchronisation; without the
    // mutex this is a data race and the total is unreliable.
    var total: u32 = 0;
    var mutex: std.Io.Mutex = .init;
    var threads: [8]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, addLocked, .{ &total, &mutex, io, 1 });
    }
    for (threads) |t| t.join();
    try out.print("locked total: {d}\n", .{total});

    // Atomics cover the simple counter case without a lock.
    var counter = std.atomic.Value(u32).init(0);
    _ = counter.fetchAdd(1, .monotonic);
    _ = counter.fetchAdd(1, .monotonic);
    try out.print("atomic: {d}\n", .{counter.load(.monotonic)});

    try out.flush();
}
