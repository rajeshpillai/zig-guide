//! title: grep
//! Search is a loop over start positions, and the exit code is the answer.

const std = @import("std");

/// The naive search, written out rather than called, because it is the thing
/// worth seeing once: try every start position, compare forward, give up on
/// the first mismatch. O(n*m) in the worst case and fine for a line of text.
fn find(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len > haystack.len) return null;

    var start: usize = 0;
    while (start + needle.len <= haystack.len) : (start += 1) {
        var i: usize = 0;
        while (i < needle.len and haystack[start + i] == needle[i]) : (i += 1) {}
        if (i == needle.len) return start;
    }
    return null;
}

/// Returns whether anything matched, which is what the exit code reports.
/// grep's contract is that "found nothing" is not an error, and a shell
/// pipeline depends on being able to tell those two apart.
fn grep(text: []const u8, pattern: []const u8, out: *std.Io.Writer) !bool {
    var lines: std.Io.Reader = .fixed(text);
    var matched = false;
    var number: usize = 0;

    while (try lines.takeDelimiter('\n')) |line| {
        number += 1;
        if (find(line, pattern) != null) {
            matched = true;
            try out.print("{d}:{s}\n", .{ number, line });
        }
    }
    return matched;
}

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout_writer.interface;

    const text =
        \\the quick brown fox
        \\jumps over the lazy dog
        \\the end
        \\
    ;

    for ([_][]const u8{ "the", "fox", "cat" }) |pattern| {
        try out.print("--- grep \"{s}\"\n", .{pattern});
        const matched = try grep(text, pattern, out);
        // 0 when something matched, 1 when nothing did. Not an error either way.
        try out.print("exit {d}\n\n", .{@intFromBool(!matched)});
    }

    try out.flush();
}
