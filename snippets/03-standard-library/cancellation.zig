//! title: Cancellation
//! native
//! How to cancel a task that runs, and the cancellation points that make it
//! possible. Built and run for the host. To cancel a task that still runs, the
//! `Io` must run the task in a different place. wasm32-wasi cannot do that.

const std = @import("std");

/// Sleeps for an hour, or until a caller cancels it. `io.sleep` is a
/// *cancellation point*: a function on `Io` that can return `error.Canceled`.
fn nap(io: std.Io) std.Io.Cancelable!void {
    try io.sleep(.fromSeconds(3600), .awake);
}

/// The same sleep, but it records how it ended. Then the program can examine
/// the group below after the sleep ends.
fn trackedNap(io: std.Io, status: *[]const u8) std.Io.Cancelable!void {
    io.sleep(.fromSeconds(3600), .awake) catch |err| {
        status.* = @errorName(err);
        return err;
    };
    status.* = "finished";
}

/// Pure computation calls nothing on `Io`. Thus it has no cancellation point,
/// and it spins forever. `io.checkCancel` is the point that you add.
fn count(io: std.Io, counter: *u64) std.Io.Cancelable!void {
    while (true) {
        try io.checkCancel();
        counter.* += 1;
    }
}

fn double(value: u32) u32 {
    return value * 2;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var buf: [512]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(io, &buf);
    const out = &file_writer.interface;

    // `cancel` is `await` plus a cancellation request. It blocks until the task
    // is done, and it returns the value that the task returned.
    var sleeping = try io.concurrent(nap, .{io});
    if (sleeping.cancel(io)) |_| {
        try out.print("nap: finished\n", .{});
    } else |err| {
        try out.print("nap: {s}\n", .{@errorName(err)});
    }

    // If you cancel a task that is already complete, the result is not an
    // error. The task has no cancellation point left, thus you get the result.
    var finished = io.async(double, .{21});
    try out.print("double: {d}\n", .{finished.cancel(io)});

    // The task sees the request only because it asks. If you remove the
    // `checkCancel`, this line never prints.
    var counter: u64 = 0;
    var counting = try io.concurrent(count, .{ io, &counter });
    if (counting.cancel(io)) |_| {
        try out.print("count: finished\n", .{});
    } else |err| {
        try out.print("count: {s}\n", .{@errorName(err)});
    }

    // A Group cancels as a whole. Each member gets the request, and `cancel`
    // returns when all of the members stop.
    //
    // Use `concurrent`, not `async`. `async` can run the task on this thread.
    // The threaded `Io` does that when it has no spare capacity: `async_limit`
    // has a default of one less than the core count. A sleep on this thread
    // sleeps for an hour here, and the program never gets to `group.cancel`.
    //
    // The program hangs when the group is equal to or larger than the core
    // count. Thus it passes on a development computer and deadlocks on a
    // small one.
    var status: [3][]const u8 = @splat("still running");
    var group: std.Io.Group = .init;
    for (&status) |*slot| try group.concurrent(io, trackedNap, .{ io, slot });
    group.cancel(io);
    for (status, 0..) |s, i| try out.print("group task {d}: {s}\n", .{ i, s });

    try out.flush();
}
