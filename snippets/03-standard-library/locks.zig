//! title: Locks and Semaphores
//! Beyond `Io.Mutex`: many readers or one writer, and counting permits.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var buf: [512]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(io, &buf);
    const out = &file_writer.interface;

    // An RwLock admits any number of readers at once, or exactly one writer.
    var rw: std.Io.RwLock = .init;

    try rw.lockShared(io);
    try rw.lockShared(io);
    try out.print("two readers: yes\n", .{});

    // `tryLock` never blocks; it reports whether it got the lock. Readers hold
    // it, so a writer cannot have it.
    try out.print("writer while reading: {}\n", .{rw.tryLock(io)});

    rw.unlockShared(io);
    rw.unlockShared(io);

    // With the readers gone the writer gets in.
    try out.print("writer once alone: {}\n", .{rw.tryLock(io)});
    rw.unlock(io);

    // A semaphore counts permits rather than granting exclusive access. Two
    // permits let two tasks past before the third has to wait.
    var sem: std.Io.Semaphore = .{ .permits = 2 };
    try sem.wait(io);
    try sem.wait(io);
    try out.print("permits taken: 2, left: {d}\n", .{sem.permits});

    // `waitTimeout` is how you avoid waiting forever for a permit that is not
    // coming. There is nothing to release this one.
    const patience: std.Io.Timeout = .{ .duration = .{ .raw = .fromMilliseconds(1), .clock = .awake } };
    if (sem.waitTimeout(io, patience)) |_| {
        try out.print("third permit: taken\n", .{});
    } else |err| {
        try out.print("third permit: {s}\n", .{@errorName(err)});
    }

    sem.post(io);
    try out.print("after post, left: {d}\n", .{sem.permits});

    try out.flush();
}
