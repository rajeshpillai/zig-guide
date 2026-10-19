//! title: What moved off std.Thread
//! Each lock and each wait primitive moved from `std.Thread` to `std.Io`. The
//! program prints this table from `@hasDecl`. Thus the compiler gives the
//! answer, not a changelog. If a name moves back, CI fails on that day.

const std = @import("std");

const Move = struct {
    /// The old name on `std.Thread`.
    was: []const u8,
    /// The new name on `std.Io`.
    now: []const u8,
};

const moves = [_]Move{
    .{ .was = "Mutex", .now = "Mutex" },
    .{ .was = "RwLock", .now = "RwLock" },
    .{ .was = "Semaphore", .now = "Semaphore" },
    .{ .was = "Condition", .now = "Condition" },
    .{ .was = "ResetEvent", .now = "Event" },
    .{ .was = "WaitGroup", .now = "Group" },
    .{ .was = "Pool", .now = "Threaded" },
};

/// The declarations that stayed on `std.Thread`. They are about an OS thread,
/// not about a wait for a thread.
const kept = [_][]const u8{ "spawn", "getCpuCount", "getCurrentId", "yield", "detach" };

fn mark(present: bool) []const u8 {
    return if (present) "present" else "gone";
}

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    inline for (moves) |m| {
        try out.print("std.Thread.{s: <11} {s: <8}  std.Io.{s: <10} {s}\n", .{
            m.was,
            comptime mark(@hasDecl(std.Thread, m.was)),
            m.now,
            comptime mark(@hasDecl(std.Io, m.now)),
        });
    }

    try out.print("\n", .{});

    inline for (kept) |name| {
        try out.print("std.Thread.{s: <13} {s}\n", .{ name, comptime mark(@hasDecl(std.Thread, name)) });
    }

    try out.flush();
}
