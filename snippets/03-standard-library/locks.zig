//! title: Locks and Semaphores
//! More than `Io.Mutex`: many readers or one writer, and a count of permits.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var buf: [512]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(io, &buf);
    const out = &file_writer.interface;

    // An RwLock admits any number of readers at the same time, or exactly one writer.
    var rw: std.Io.RwLock = .init;

    try rw.lockShared(io);
    try rw.lockShared(io);
    try out.print("two readers: yes\n", .{});

    // `tryLock` never blocks. It tells you if it got the lock. Readers hold the
    // lock, thus a writer cannot get it.
    try out.print("writer while reading: {}\n", .{rw.tryLock(io)});

    rw.unlockShared(io);
    rw.unlockShared(io);

    // When the readers release the lock, the writer gets it.
    try out.print("writer once alone: {}\n", .{rw.tryLock(io)});
    rw.unlock(io);

    // A semaphore counts permits. It does not give exclusive access. With two
    // permits, two tasks continue, and the third task must wait.
    var sem: std.Io.Semaphore = .{ .permits = 2 };
    try sem.wait(io);
    try sem.wait(io);
    try out.print("permits taken: 2, left: {d}\n", .{sem.permits});

    // Use `waitTimeout` when a permit may never come. Then the task does not
    // wait forever. Here, no code releases a permit.
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
