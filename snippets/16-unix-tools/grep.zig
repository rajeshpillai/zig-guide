//! title: grep
//! Search is a loop over start positions, and the exit code is the answer.

const std = @import("std");

/// The simple search, written out here, so that you can see it one time.
/// Try each start position, compare forward, and stop at the first mismatch.
/// O(n*m) in the worst case, and good enough for a line of text.
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

/// Returns true if a line matched. The exit code reports this result.
/// The contract of grep is that "found nothing" is not an error. A shell
/// pipeline must see the difference between those two results.
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
        // 0 when a line matched, 1 when no line matched. Neither is an error.
        try out.print("exit {d}\n\n", .{@intFromBool(!matched)});
    }

    try out.flush();
}
