//! title: The Io Interface
//! Each operation that can block takes an `Io`. The caller selects the implementation.

const std = @import("std");
const expect = std.testing.expect;

// A function that takes an `Io` tells you in its signature that it can block.
// For example, it can read a clock, use a file, or wait on the network. The
// function does not decide *how* the blocking operation runs. The `Io` that
// the function receives decides.
fn elapsedNanos(io: std.Io) i96 {
    const start = std.Io.Clock.Timestamp.now(io, .awake);
    var acc: u64 = 0;
    for (0..10_000) |i| acc +%= i;
    std.mem.doNotOptimizeAway(acc);
    const end = std.Io.Clock.Timestamp.now(io, .awake);
    return start.durationTo(end).raw.toNanoseconds();
}

test "get an Io and pass it down" {
    // In a test, the instance is `std.testing.io`. In a program, it is
    // `init.io`, the field on the `std.process.Init` that `main` receives.
    // `std.Io.Threaded`, a real thread pool, is behind the two instances.
    const io = std.testing.io;
    try expect(elapsedNanos(io) >= 0);
}

fn double(out: *u32, value: u32) void {
    out.* = value * 2;
}

test "the same Io is what makes concurrency work" {
    // Each blocking operation goes through the interface. Thus the interface
    // can also *schedule* the operation. `io.async` starts a task, and the
    // Threaded io runs the task on a different thread. With an event-loop io,
    // the identical call suspends a coroutine. The caller does not change.
    const io = std.testing.io;

    var a: u32 = 0;
    var b: u32 = 0;
    var first = io.async(double, .{ &a, 10 });
    var second = io.async(double, .{ &b, 20 });
    first.await(io);
    second.await(io);

    try expect(a == 20 and b == 40);
}
