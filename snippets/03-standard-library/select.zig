//! title: Select
//! native
//! Wait for the task that completes first. Built and run for the host. A race
//! needs the tasks to run at the same time. That needs `io.concurrent`, and
//! single-threaded wasm cannot give it.

const std = @import("std");

/// The result of the winner arrives as this union. The tag is the arm that
/// made the result.
const Outcome = union(enum) {
    reply: u32,
    timeout: void,
};

fn request(io: std.Io, delay: std.Io.Duration) u32 {
    io.sleep(delay, .awake) catch return 0;
    return 42;
}

fn deadline(io: std.Io, after: std.Io.Duration) void {
    io.sleep(after, .awake) catch {};
}

/// Runs the two arms, reports the arm that completed first, and cancels the
/// other arm. The two durations are different by an hour. Thus the code
/// decides the winner, not the load on the computer.
fn race(
    io: std.Io,
    out: *std.Io.Writer,
    reply_after: std.Io.Duration,
    timeout_after: std.Io.Duration,
) !void {
    var slots: [2]Outcome = undefined;
    var select: std.Io.Select(Outcome) = .init(io, &slots);

    try select.concurrent(.reply, request, .{ io, reply_after });
    try select.concurrent(.timeout, deadline, .{ io, timeout_after });

    switch (try select.await()) {
        .reply => |value| try out.print("reply: {d}\n", .{value}),
        .timeout => try out.print("timed out\n", .{}),
    }

    // The arm that lost still runs. A select owns its tasks. Thus a cancel of
    // the select stops the arm, and no task remains when this function returns.
    select.cancelDiscard();
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var buf: [256]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(io, &buf);
    const out = &file_writer.interface;

    try race(io, out, .fromMilliseconds(1), .fromSeconds(3600));
    try race(io, out, .fromSeconds(3600), .fromMilliseconds(1));

    try out.flush();
}
