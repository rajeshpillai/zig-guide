//! title: Select
//! native
//! Waiting for whichever task finishes first. Built and run for the host: a
//! race needs the tasks to be running at the same time, which is `io.concurrent`
//! and not something single-threaded wasm can offer.

const std = @import("std");

/// Whichever arm wins, the result arrives as this union, tagged with the arm
/// that produced it.
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

/// Runs both arms and reports the one that finished first, cancelling the
/// other. The margin between the two durations is an hour, so the winner is
/// decided by the code and not by how loaded the machine is.
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

    // The losing arm is still running. A select owns its tasks, so cancelling
    // the select stops it, and nothing is left behind when this returns.
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
