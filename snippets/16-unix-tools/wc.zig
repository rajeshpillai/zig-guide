//! title: wc
//! Counting words means counting the moments you enter one.

const std = @import("std");

const Counts = struct { lines: usize = 0, words: usize = 0, bytes: usize = 0 };

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 11 or c == 12;
}

/// One pass, one byte at a time, one bit of state. `in_word` is the state
/// machine: a word is counted when the input crosses from space into non-space,
/// so runs of spaces cost nothing and the input is never looked at twice.
fn count(text: []const u8) Counts {
    var c: Counts = .{};
    var in_word = false;

    for (text) |ch| {
        c.bytes += 1;
        if (ch == '\n') c.lines += 1;

        if (isSpace(ch)) {
            in_word = false;
        } else if (!in_word) {
            in_word = true;
            c.words += 1;
        }
    }
    return c;
}

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout_writer.interface;

    const samples = [_][]const u8{
        "hello world\n",
        "  hello   world  \n",
        "one\ntwo\nthree\n",
        "no newline at the end",
        "",
    };

    for (samples) |text| {
        const c = count(text);
        try out.print("{d:>3} {d:>3} {d:>3}  ", .{ c.lines, c.words, c.bytes });
        try printEscaped(out, text);
        try out.writeAll("\n");
    }

    try out.flush();
}

/// Show the sample with its whitespace visible, so the counts can be checked.
fn printEscaped(out: *std.Io.Writer, text: []const u8) !void {
    try out.writeAll("\"");
    for (text) |ch| {
        if (ch == '\n') try out.writeAll("\\n") else try out.writeByte(ch);
    }
    try out.writeAll("\"");
}
