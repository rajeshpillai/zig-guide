//! title: Reading Line by Line
//! Line endings, a line longer than the buffer, and a large file read
//! through a small one.

const std = @import("std");

const Io = std.Io;

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var out_buf: [2048]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(io, &out_buf);
    const out = &stdout.interface;
    defer out.flush() catch {};

    const dir = Io.Dir.cwd();

    // 1. Three files with the same two lines and different endings.
    try out.print("1. line endings\n", .{});
    const endings = [_]struct { name: []const u8, data: []const u8 }{
        .{ .name = "unix.txt", .data = "one\ntwo\n" },
        .{ .name = "no-final.txt", .data = "one\ntwo" },
        .{ .name = "windows.txt", .data = "one\r\ntwo\r\n" },
    };
    for (endings) |e| {
        try dir.writeFile(io, .{ .sub_path = e.name, .data = e.data });
        try out.print("   {s}\n", .{e.name});
        try printLines(io, dir, e.name, out);
    }

    // 2. A line longer than the reader's buffer.
    try out.print("2. a long line\n", .{});
    try dir.writeFile(io, .{
        .sub_path = "long.txt",
        .data = "short\n" ++ @as([40]u8, @splat('x')) ++ "\nafter\n",
    });
    try readSkippingLong(io, dir, "long.txt", out);

    // 3. A file much bigger than the buffer that reads it.
    try out.print("3. a large file\n", .{});
    try writeNumberedLines(io, dir, "big.txt", 10_000);
    try countLines(io, dir, "big.txt", out);

    for ([_][]const u8{ "unix.txt", "no-final.txt", "windows.txt", "long.txt", "big.txt" }) |name| {
        try dir.deleteFile(io, name);
    }
}

fn printLines(io: Io, dir: Io.Dir, name: []const u8, out: *Io.Writer) !void {
    const file = try dir.openFile(io, name, .{});
    defer file.close(io);

    var buf: [64]u8 = undefined;
    var reader = file.reader(io, &buf);

    var n: usize = 1;
    while (try reader.interface.takeDelimiter('\n')) |raw| : (n += 1) {
        // A file written on Windows ends each line with "\r\n". Splitting on
        // '\n' leaves the '\r' on the end of the line, so strip it.
        const line = std.mem.trimEnd(u8, raw, "\r");
        try out.print("     line {d}: \"{f}\" -> \"{s}\"\n", .{ n, std.zig.fmtString(raw), line });
    }
}

fn readSkippingLong(io: Io, dir: Io.Dir, name: []const u8, out: *Io.Writer) !void {
    const file = try dir.openFile(io, name, .{});
    defer file.close(io);

    // 16 bytes of buffer. The longest line the reader can return is 15
    // characters plus the newline.
    var buf: [16]u8 = undefined;
    var reader = file.reader(io, &buf);
    const r = &reader.interface;

    var n: usize = 1;
    while (true) : (n += 1) {
        const line = r.takeDelimiter('\n') catch |err| switch (err) {
            error.StreamTooLong => {
                // Nothing was consumed. Skip to the end of this line and go on.
                const skipped = try r.discardDelimiterInclusive('\n');
                try out.print("   line {d}: StreamTooLong, skipped {d} bytes\n", .{ n, skipped });
                continue;
            },
            else => |e| return e,
        } orelse break;
        try out.print("   line {d}: {s}\n", .{ n, line });
    }
}

fn writeNumberedLines(io: Io, dir: Io.Dir, name: []const u8, count: usize) !void {
    const file = try dir.createFile(io, name, .{});
    defer file.close(io);

    var buf: [4096]u8 = undefined;
    var writer = file.writer(io, &buf);
    for (1..count + 1) |i| try writer.interface.print("line {d}\n", .{i});
    try writer.interface.flush();
}

fn countLines(io: Io, dir: Io.Dir, name: []const u8, out: *Io.Writer) !void {
    const file = try dir.openFile(io, name, .{});
    defer file.close(io);

    var buf: [256]u8 = undefined;
    var reader = file.reader(io, &buf);

    var lines: usize = 0;
    var bytes: usize = 0;
    var last: [16]u8 = undefined;
    var last_len: usize = 0;
    while (try reader.interface.takeDelimiter('\n')) |line| {
        lines += 1;
        bytes += line.len + 1;
        // `line` points into `buf`, and the next read overwrites it.
        // Keeping it past this iteration means copying it out.
        @memcpy(last[0..line.len], line);
        last_len = line.len;
    }
    try out.print("   file size {d} bytes, buffer {d} bytes\n", .{ try file.length(io), buf.len });
    try out.print("   {d} lines, {d} bytes, last line \"{s}\"\n", .{ lines, bytes, last[0..last_len] });
}
