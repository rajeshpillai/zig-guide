//! title: An Append-Only Record Store
//! Never modify what is written. Deleting is something you add.

const std = @import("std");

/// One record per line, fields separated by `|`. The separator is the whole
/// design decision, and it forces the next one: what happens when a value
/// contains it.
pub const Record = struct {
    op: enum { put, delete },
    key: []const u8,
    value: []const u8,
};

/// Escape the separator and the newline, so a record can hold either.
/// Without this a value containing `|` silently becomes two fields, and the
/// corruption is invisible until something reads it back.
fn writeEscaped(out: *std.Io.Writer, text: []const u8) !void {
    for (text) |c| switch (c) {
        '|' => try out.writeAll("\\p"),
        '\n' => try out.writeAll("\\n"),
        '\\' => try out.writeAll("\\\\"),
        else => try out.writeByte(c),
    };
}

fn unescape(dest: []u8, text: []const u8) ![]const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (n += 1) {
        if (n == dest.len) return error.TooLong;
        if (text[i] == '\\' and i + 1 < text.len) {
            dest[n] = switch (text[i + 1]) {
                'p' => '|',
                'n' => '\n',
                else => '\\',
            };
            i += 2;
        } else {
            dest[n] = text[i];
            i += 1;
        }
    }
    return dest[0..n];
}

pub fn append(log: *std.Io.Writer, record: Record) !void {
    try log.writeAll(if (record.op == .put) "put|" else "del|");
    try writeEscaped(log, record.key);
    try log.writeAll("|");
    try writeEscaped(log, record.value);
    try log.writeAll("\n");
}

/// Read the log forward, keeping the last thing said about each key. A delete
/// is a record, not the absence of one, which is the only way an append-only
/// file can express removal.
pub fn lookup(log: []const u8, key: []const u8, scratch: []u8) !?[]const u8 {
    var result: ?[]const u8 = null;
    var used: usize = 0;

    var lines = std.mem.splitScalar(u8, log, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var fields = std.mem.splitScalar(u8, line, '|');
        const op = fields.next() orelse continue;
        const raw_key = fields.next() orelse continue;
        const raw_value = fields.next() orelse "";

        var key_buf: [128]u8 = undefined;
        const this_key = try unescape(&key_buf, raw_key);
        if (!std.mem.eql(u8, this_key, key)) continue;

        if (std.mem.eql(u8, op, "del")) {
            result = null;
        } else {
            const value = try unescape(scratch[used..], raw_value);
            used += value.len;
            result = value;
        }
    }
    return result;
}

pub fn main(init: std.process.Init) !void {
    var buf: [2048]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout_writer.interface;

    // A buffer standing in for the file. Every write is an append; nothing
    // here can seek backwards, which is the constraint being explored.
    var file: [1024]u8 = undefined;
    var log: std.Io.Writer = .fixed(&file);

    try append(&log, .{ .op = .put, .key = "alice", .value = "engineer" });
    try append(&log, .{ .op = .put, .key = "bob", .value = "designer" });
    try append(&log, .{ .op = .put, .key = "alice", .value = "architect" });
    try append(&log, .{ .op = .delete, .key = "bob", .value = "" });
    try append(&log, .{ .op = .put, .key = "carol", .value = "a|b\nc" });

    const written = log.buffered();
    try out.print("the log, {d} bytes:\n", .{written.len});
    try out.print("{s}\n", .{written});

    var scratch: [256]u8 = undefined;
    var live: usize = 0;
    for ([_][]const u8{ "alice", "bob", "carol", "dave" }) |key| {
        if (try lookup(written, key, &scratch)) |value| {
            live += 1;
            try out.print("{s: <6} -> \"{s}\"\n", .{ key, value });
        } else {
            try out.print("{s: <6} -> (absent)\n", .{key});
        }
    }

    try out.print("\n5 records written, {d} keys live, and the file only ever grew\n", .{live});
    try out.flush();
}
