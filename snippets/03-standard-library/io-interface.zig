//! title: The Io Interface
//! Anything that can block takes an `Io`. The caller picks the implementation.

const std = @import("std");
const expect = std.testing.expect;

// A function that takes an `Io` is announcing, in its signature, that it may
// block: read a clock, touch a file, wait on the network. It does not decide
// *how* that blocking is serviced; the `Io` it is handed does.
fn elapsedNanos(io: std.Io) i96 {
    const start = std.Io.Clock.Timestamp.now(io, .awake);
    var acc: u64 = 0;
    for (0..10_000) |i| acc +%= i;
    std.mem.doNotOptimizeAway(acc);
    const end = std.Io.Clock.Timestamp.now(io, .awake);
    return start.durationTo(end).raw.toNanoseconds();
}

test "get an Io and pass it down" {
    // In a test the instance is `std.testing.io`. In a program it is
    // `init.io`, the field on the `std.process.Init` your `main` receives.
    // Both are backed by `std.Io.Threaded`: a real thread pool.
    const io = std.testing.io;
    try expect(elapsedNanos(io) >= 0);
}

fn double(out: *u32, value: u32) void {
    out.* = value * 2;
}

test "the same Io is what makes concurrency work" {
    // Because blocking goes through the interface, the interface can also
    // *schedule* it. `io.async` starts a task; the Threaded io runs it on
    // another thread. Swap in an event-loop io and the identical call would
    // suspend a coroutine instead. The calling code does not change.
    const io = std.testing.io;

    var a: u32 = 0;
    var b: u32 = 0;
    var first = io.async(double, .{ &a, 10 });
    var second = io.async(double, .{ &b, 20 });
    first.await(io);
    second.await(io);

    try expect(a == 20 and b == 40);
}
