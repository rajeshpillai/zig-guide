//! title: cut
//! Splitting on a delimiter, and the edge cases that decide whether it is correct.

const std = @import("std");

/// Field `n` of `line`, counting from 1 the way cut does. Returns null when
/// the line has fewer fields, which is different from the field being empty
/// and has to stay different.
fn field(line: []const u8, delimiter: u8, n: usize) ?[]const u8 {
    if (n == 0) return null;

    var it = std.mem.splitScalar(u8, line, delimiter);
    var i: usize = 1;
    while (it.next()) |part| : (i += 1) {
        if (i == n) return part;
    }
    return null;
}

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout_writer.interface;

    const rows = [_][]const u8{
        "alice:30:london",
        "bob:25:paris",
        // An empty field in the middle: two delimiters with nothing between.
        "carol::berlin",
        // Fewer fields than asked for.
        "dave",
    };

    for ([_]usize{ 1, 2 }) |n| {
        try out.print("--- field {d}\n", .{n});
        for (rows) |row| {
            if (field(row, ':', n)) |value| {
                try out.print("{s} -> \"{s}\"\n", .{ row, value });
            } else {
                try out.print("{s} -> (no such field)\n", .{row});
            }
        }
        try out.writeAll("\n");
    }

    // Splitting never invents or loses a field: n delimiters give n+1 fields,
    // even when some of them are empty.
    var it = std.mem.splitScalar(u8, "carol::berlin", ':');
    var parts: usize = 0;
    while (it.next()) |_| parts += 1;
    try out.print("\"carol::berlin\" has {d} fields\n", .{parts});

    try out.flush();
}
