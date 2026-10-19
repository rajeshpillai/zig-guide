//! title: Atomics
//! One counter, and all the ways to add one to it. This program runs in your
//! browser on a single-threaded target. An atomic operation does the same
//! thing when no second thread exists.

const std = @import("std");

const Atomic = std.atomic.Value;

/// Two workers increment one plain counter. The code writes each step of the
/// read-modify-write in the order that a race can run the steps. This code has
/// no race. It shows the result that a race makes.
fn lostUpdate() u32 {
    var plain: u32 = 0;
    const a_read = plain; // worker A reads 0
    const b_read = plain; // worker B reads 0
    plain = b_read + 1; // worker B writes 1
    plain = a_read + 1; // worker A writes 1, over the value from B
    return plain;
}

/// The same two increments. No other operation can occur between the read and
/// the write.
fn atomicIncrements() u32 {
    var counter: Atomic(u32) = .init(0);
    _ = counter.fetchAdd(1, .monotonic);
    _ = counter.fetchAdd(1, .monotonic);
    return counter.load(.monotonic);
}

/// A multiplication needs a loop, because no `fetchMul` exists. Read the value,
/// calculate the new value, and swap only if no other thread changed it.
fn multiplyBy(counter: *Atomic(u32), factor: u32) void {
    var seen = counter.load(.monotonic);
    while (counter.cmpxchgWeak(seen, seen * factor, .monotonic, .monotonic)) |actual| {
        seen = actual;
    }
}

/// The `.release` store promises that the write to `payload` is visible to
/// each reader that gets `true` from an `.acquire` load.
fn publish(payload: *u32, ready: *Atomic(bool), value: u32) void {
    payload.* = value;
    ready.store(true, .release);
}

/// The other half of the pair. Null means that the writer did not publish yet.
fn consume(payload: *const u32, ready: *const Atomic(bool)) ?u32 {
    if (!ready.load(.acquire)) return null;
    return payload.*;
}

/// A lock is not a primitive. One compare-and-swap takes the lock, and one
/// ordered store releases the lock. The type needs nothing more.
/// `std.atomic.Mutex` is this type.
const SpinLock = enum(u8) {
    unlocked,
    locked,

    fn tryLock(self: *SpinLock) bool {
        return @cmpxchgStrong(SpinLock, self, .unlocked, .locked, .acquire, .monotonic) == null;
    }

    fn unlock(self: *SpinLock) void {
        @atomicStore(SpinLock, self, .unlocked, .release);
    }
};

pub fn main(init: std.process.Init) !void {
    var buf: [512]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    try out.print("two increments, plain:  {d}\n", .{lostUpdate()});
    try out.print("two increments, atomic: {d}\n", .{atomicIncrements()});

    // Each fetch operation returns the value from before the change. Thus the
    // counter can give tickets: no two callers get the same number.
    var counter: Atomic(u32) = .init(2);
    const before = counter.fetchAdd(10, .monotonic);
    try out.print("fetchAdd returned {d}, counter is now {d}\n", .{ before, counter.load(.monotonic) });

    multiplyBy(&counter, 3);
    try out.print("after the CAS loop: {d}\n", .{counter.load(.monotonic)});

    // A compare-and-swap returns null when it is successful. When it fails, it
    // returns the value that was really there.
    const wrong_guess = counter.cmpxchgStrong(0, 99, .monotonic, .monotonic);
    try out.print("cmpxchg against a wrong guess: {?d}\n", .{wrong_guess});

    var payload: u32 = 0;
    var ready: Atomic(bool) = .init(false);
    try out.print("before publish: {?d}\n", .{consume(&payload, &ready)});
    publish(&payload, &ready, 7);
    try out.print("after publish:  {?d}\n", .{consume(&payload, &ready)});

    var lock: SpinLock = .unlocked;
    try out.print("first tryLock:  {}\n", .{lock.tryLock()});
    try out.print("second tryLock: {}\n", .{lock.tryLock()});
    lock.unlock();
    try out.print("after unlock:   {}\n", .{lock.tryLock()});
    lock.unlock();

    // Ordering is an argument to each operation. The loop prints the orderings,
    // weakest first. No separate fence builtin exists.
    try out.print("orderings:", .{});
    for (std.meta.tags(std.lang.AtomicOrder)) |order| {
        try out.print(" .{t}", .{order});
    }
    try out.print("\n", .{});

    try out.flush();
}
