//! title: Choosing an Io
//! native
//! Constructing an `Io` yourself instead of taking the one `main` was given.
//! Built and run for the host, because the point is the difference between an
//! implementation that has threads and one that does not.

const std = @import("std");

fn double(value: u32) u32 {
    return value * 2;
}

/// Ordinary library code. It never names an implementation, so it works with
/// whichever one the caller built.
fn run(io: std.Io, label: []const u8, out: *std.Io.Writer) !void {
    var future = io.async(double, .{21});
    try out.print("{s}: async {d}", .{ label, future.await(io) });

    if (io.concurrent(double, .{21})) |handle| {
        var pending = handle;
        try out.print(", concurrent {d}\n", .{pending.await(io)});
    } else |err| {
        try out.print(", concurrent {s}\n", .{@errorName(err)});
    }
}

pub fn main(init: std.process.Init) !void {
    var buf: [512]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    // A thread pool. The allocator is only used to spawn tasks; everything
    // else in the implementation is allocation-free.
    var pool: std.Io.Threaded = .init(init.gpa, .{});
    defer pool.deinit();
    try run(pool.io(), "threaded", out);

    // The same implementation with concurrency turned off. `async` still works
    // because it is allowed to run the task inline; `concurrent` cannot.
    var capped: std.Io.Threaded = .init(init.gpa, .{ .concurrent_limit = .nothing });
    defer capped.deinit();
    try run(capped.io(), "capped", out);

    // A statically initialised instance that spawns nothing at all. This is
    // what a target without threads gets, and it needs no allocator.
    var lone: std.Io.Threaded = .init_single_threaded;
    try run(lone.io(), "single-threaded", out);

    try out.flush();
}
