//! title: Choosing an Io
//! native
//! Make an `Io` yourself. Do not use the `Io` that `main` got.
//! Built and run for the host. The program shows the difference between an
//! implementation that has threads and an implementation that does not.

const std = @import("std");

fn double(value: u32) u32 {
    return value * 2;
}

/// Usual library code. It never names an implementation. Thus it works with
/// the implementation that the caller made.
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

    // A thread pool. The implementation uses the allocator only to spawn
    // tasks. All other parts of the implementation do not allocate.
    var pool: std.Io.Threaded = .init(init.gpa, .{});
    defer pool.deinit();
    try run(pool.io(), "threaded", out);

    // The same implementation without concurrency. `async` still works,
    // because it can run the task inline. `concurrent` cannot work.
    var capped: std.Io.Threaded = .init(init.gpa, .{ .concurrent_limit = .nothing });
    defer capped.deinit();
    try run(capped.io(), "capped", out);

    // A static instance that spawns nothing. A target without threads gets
    // this instance, and it needs no allocator.
    var lone: std.Io.Threaded = .init_single_threaded;
    try run(lone.io(), "single-threaded", out);

    try out.flush();
}
