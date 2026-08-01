//! title: Tokenizing a Command Line
//! Turning "ls -la /tmp" into the argv a shell needs, without copying anything.

const std = @import("std");

/// Split on runs of whitespace. Returns slices of `line`, so nothing is
/// copied and nothing is allocated, and the result is only valid while `line`
/// is.
///
/// A run of spaces produces no empty argument, which is the opposite of the
/// rule `cut` needs. A command line is not a delimited record: the delimiter
/// is separation, not structure, so `ls   -la` is two arguments.
fn tokenize(line: []const u8, out: [][]const u8) ![][]const u8 {
    var n: usize = 0;
    var i: usize = 0;

    while (i < line.len) {
        while (i < line.len and isSpace(line[i])) i += 1;
        if (i == line.len) break;

        const start = i;
        while (i < line.len and !isSpace(line[i])) i += 1;

        if (n == out.len) return error.TooManyArguments;
        out[n] = line[start..i];
        n += 1;
    }
    return out[0..n];
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout_writer.interface;

    var argv: [8][]const u8 = undefined;

    const lines = [_][]const u8{
        "ls -la /tmp",
        "  spaced   out   ",
        "single",
        "",
        "   ",
    };

    for (lines) |line| {
        const args = try tokenize(line, &argv);
        try out.print("\"{s}\"\n  {d} args:", .{ line, args.len });
        for (args) |arg| try out.print(" [{s}]", .{arg});
        try out.writeAll("\n");
    }

    // The first token is what a shell would exec; the rest are handed to it.
    const args = try tokenize("grep -n main build.zig", &argv);
    try out.print("\ncommand: {s}\n", .{args[0]});
    for (args[1..], 1..) |arg, i| try out.print("  argv[{d}] = {s}\n", .{ i, arg });

    try out.flush();
}
