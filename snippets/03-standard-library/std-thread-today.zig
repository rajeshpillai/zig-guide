//! title: What moved off std.Thread
//! Every lock and every wait primitive left `std.Thread` for `std.Io`. This
//! table is printed from `@hasDecl`, so the compiler is answering rather than
//! a changelog, and CI fails the day any of it moves back.

const std = @import("std");

const Move = struct {
    /// The name it had on `std.Thread`.
    was: []const u8,
    /// The name it has on `std.Io`.
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

/// What `std.Thread` kept: the parts that are genuinely about an OS thread
/// rather than about waiting for one.
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
