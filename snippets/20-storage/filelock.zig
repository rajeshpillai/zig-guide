//! title: Two Writers, One File
//! native
//! What a lost update looks like, and the lock that prevents it.
//!
//! `//! native` because it needs a real filesystem and real threads. CI builds
//! it and runs it on the host, so the numbers are produced rather than
//! described.
//!
//! Deliberately no `.expected` file. The unlocked total is different on every
//! run, which is the entire point of the demonstration and also the reason it
//! cannot be pinned: asserting one value would make the nightly fail on an
//! unchanged tree. CI runs it and requires exit 0, which is what verifies the
//! code still compiles and still terminates.

const std = @import("std");

const rounds = 200;

/// Read a counter, add one, write it back. Three steps, and the gap between
/// the read and the write is where the other writer gets in.
fn increment(dir: *std.Io.Dir, io: std.Io, name: []const u8, lock: ?*std.Io.Mutex) void {
    for (0..rounds) |_| {
        if (lock) |m| m.lock(io) catch return;
        defer if (lock) |m| m.unlock(io);

        var buf: [32]u8 = undefined;
        const current = blk: {
            const file = dir.openFile(io, name, .{}) catch break :blk @as(u64, 0);
            defer file.close(io);
            var reader = file.readerStreaming(io, &buf);
            const text = reader.interface.allocRemaining(std.heap.page_allocator, .unlimited) catch break :blk @as(u64, 0);
            defer std.heap.page_allocator.free(text);
            break :blk std.fmt.parseInt(u64, std.mem.trim(u8, text, " \n"), 10) catch 0;
        };

        var out_buf: [32]u8 = undefined;
        const text = std.mem.print(&out_buf, "{d}", .{current + 1}) catch continue;

        const file = dir.createFile(io, name, .{ .truncate = true }) catch continue;
        defer file.close(io);
        var writer = file.writerStreaming(io, &buf);
        writer.interface.writeAll(text) catch continue;
        writer.interface.flush() catch continue;
    }
}

fn run(dir: *std.Io.Dir, io: std.Io, name: []const u8, lock: ?*std.Io.Mutex) !u64 {
    {
        const file = try dir.createFile(io, name, .{ .truncate = true });
        defer file.close(io);
        var buf: [8]u8 = undefined;
        var writer = file.writerStreaming(io, &buf);
        try writer.interface.writeAll("0");
        try writer.interface.flush();
    }

    const a = try std.Thread.spawn(.{}, increment, .{ dir, io, name, lock });
    const b = try std.Thread.spawn(.{}, increment, .{ dir, io, name, lock });
    a.join();
    b.join();

    var buf: [32]u8 = undefined;
    const file = try dir.openFile(io, name, .{});
    defer file.close(io);
    var reader = file.readerStreaming(io, &buf);
    const text = try reader.interface.allocRemaining(std.heap.page_allocator, .unlimited);
    defer std.heap.page_allocator.free(text);
    return std.fmt.parseInt(u64, std.mem.trim(u8, text, " \n"), 10) catch 0;
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(io, &buf);
    const out = &stdout_writer.interface;

    // The working directory, with names nothing else uses, cleaned up at the
    // end. Creating a directory is one more thing to tidy away on every exit
    // path, and this demo does not need one.
    var dir = std.Io.Dir.cwd();
    defer dir.deleteFile(io, "storage-unlocked.tmp") catch {};
    defer dir.deleteFile(io, "storage-locked.tmp") catch {};

    const expected = rounds * 2;

    const lost = try run(&dir, io, "storage-unlocked.tmp", null);
    try out.print("two threads, {d} increments each\n\n", .{rounds});
    try out.print("without a lock: {d}, expected {d}\n", .{ lost, expected });
    try out.print("  updates lost: {}\n\n", .{lost < expected});

    var mutex: std.Io.Mutex = .init;
    const kept = try run(&dir, io, "storage-locked.tmp", &mutex);
    try out.print("with a lock:    {d}, expected {d}\n", .{ kept, expected });
    try out.print("  updates lost: {}\n", .{kept < expected});

    try out.flush();
}
