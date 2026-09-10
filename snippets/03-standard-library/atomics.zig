//! title: Atomics
//! One counter, and every way to add one to it. This runs in your browser on a
//! single-threaded target, because what an atomic operation *is* does not
//! depend on having a second thread to race against.

const std = @import("std");

const Atomic = std.atomic.Value;

/// Two workers increment one plain counter, with the read-modify-write spelled
/// out in the order a race would have run it. Nothing here races: this is what
/// a race produces.
fn lostUpdate() u32 {
    var plain: u32 = 0;
    const a_read = plain; // worker A reads 0
    const b_read = plain; // worker B reads 0
    plain = b_read + 1; // worker B writes 1
    plain = a_read + 1; // worker A writes 1, over the top of B
    return plain;
}

/// The same two increments, with nothing able to get between the read and the
/// write.
fn atomicIncrements() u32 {
    var counter: Atomic(u32) = .init(0);
    _ = counter.fetchAdd(1, .monotonic);
    _ = counter.fetchAdd(1, .monotonic);
    return counter.load(.monotonic);
}

/// Multiplying takes a loop, because there is no `fetchMul`: read the value,
/// compute the new one, and swap only if nobody changed it underneath us.
fn multiplyBy(counter: *Atomic(u32), factor: u32) void {
    var seen = counter.load(.monotonic);
    while (counter.cmpxchgWeak(seen, seen * factor, .monotonic, .monotonic)) |actual| {
        seen = actual;
    }
}

/// The `.release` store promises that the write to `payload` is visible to
/// anything that reads `true` back through an `.acquire` load.
fn publish(payload: *u32, ready: *Atomic(bool), value: u32) void {
    payload.* = value;
    ready.store(true, .release);
}

/// The other half of the pair. Null means the writer has not published yet.
fn consume(payload: *const u32, ready: *const Atomic(bool)) ?u32 {
    if (!ready.load(.acquire)) return null;
    return payload.*;
}

/// A lock is not a primitive. One compare-and-swap takes it, one ordered store
/// drops it, and that is the whole type. `std.atomic.Mutex` is this.
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

    // Every fetch operation returns the value from before the change, which is
    // what makes it a ticket dispenser: no two callers get the same number.
    var counter: Atomic(u32) = .init(2);
    const before = counter.fetchAdd(10, .monotonic);
    try out.print("fetchAdd returned {d}, counter is now {d}\n", .{ before, counter.load(.monotonic) });

    multiplyBy(&counter, 3);
    try out.print("after the CAS loop: {d}\n", .{counter.load(.monotonic)});

    // A compare-and-swap returns null when it succeeded, and the value that
    // was really there when it did not.
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

    // Ordering is an argument to each operation, weakest first. There is no
    // separate fence builtin to reach for.
    try out.print("orderings:", .{});
    for (std.meta.tags(std.lang.AtomicOrder)) |order| {
        try out.print(" .{t}", .{order});
    }
    try out.print("\n", .{});

    try out.flush();
}
