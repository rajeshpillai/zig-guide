//! title: Cancellation
//! native
//! Cancelling a running task, and the cancellation points that let it happen.
//! Built and run for the host: cancelling a task that is still running needs an
//! `Io` that can run it somewhere else, and wasm32-wasi cannot.

const std = @import("std");

/// Sleeps for an hour, or until someone cancels it. `io.sleep` is a
/// *cancellation point*: a function on `Io` that can return `error.Canceled`.
fn nap(io: std.Io) std.Io.Cancelable!void {
    try io.sleep(.fromSeconds(3600), .awake);
}

/// Same nap, but recording how it ended so the group below can be inspected
/// after the fact.
fn trackedNap(io: std.Io, status: *[]const u8) std.Io.Cancelable!void {
    io.sleep(.fromSeconds(3600), .awake) catch |err| {
        status.* = @errorName(err);
        return err;
    };
    status.* = "finished";
}

/// Pure computation calls nothing on `Io`, so it has no cancellation point of
/// its own and would spin forever. `io.checkCancel` is the point you add.
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

    // `cancel` is `await` plus a cancellation request: it blocks until the task
    // is done, and hands back what the task returned.
    var sleeping = try io.concurrent(nap, .{io});
    if (sleeping.cancel(io)) |_| {
        try out.print("nap: finished\n", .{});
    } else |err| {
        try out.print("nap: {s}\n", .{@errorName(err)});
    }

    // Cancelling a task that already finished is not an error. There was no
    // cancellation point left to reach, so you get the result.
    var finished = io.async(double, .{21});
    try out.print("double: {d}\n", .{finished.cancel(io)});

    // The counting task only notices because it asks. Take the `checkCancel`
    // out and this line never prints.
    var counter: u64 = 0;
    var counting = try io.concurrent(count, .{ io, &counter });
    if (counting.cancel(io)) |_| {
        try out.print("count: finished\n", .{});
    } else |err| {
        try out.print("count: {s}\n", .{@errorName(err)});
    }

    // A Group cancels as a whole: every member gets the request, and `cancel`
    // returns once all of them have stopped.
    var status: [3][]const u8 = @splat("still running");
    var group: std.Io.Group = .init;
    for (&status) |*slot| group.async(io, trackedNap, .{ io, slot });
    group.cancel(io);
    for (status, 0..) |s, i| try out.print("group task {d}: {s}\n", .{ i, s });

    try out.flush();
}
