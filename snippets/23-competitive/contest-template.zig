//! title: A Contest Template
//! native
//! The one program in this section that reads real stdin. Every other chapter
//! parses a const string through a `*std.Io.Reader`; this one hands the same
//! kind of reader a file handle instead. CI feeds it the sibling `.stdin` file
//! and diffs stdout, exactly as a judge would.

const std = @import("std");

/// The largest `n` the problem promises. Contest statements always give one,
/// and sizing storage from it means no allocation at all.
const max_n = 200_000;

/// Declared at container level, not inside `main`.
///
/// 200,000 values of 8 bytes is 1.6 MB. A local array lives on the stack,
/// which is commonly 8 MB on Linux and often less on a judge, so a bound ten
/// times larger would crash before the first read. A global lives in the
/// program's zeroed data instead, and is reused by every test case.
var values: [max_n]i64 = undefined;

/// Skip whitespace, then read one integer.
///
/// It reads byte by byte and never looks at line breaks, so it does not care
/// how the input is laid out. Judges promise the tokens and their order, not
/// which line each one is on.
fn nextInt(in: *std.Io.Reader) !i64 {
    var c = try in.takeByte();
    while (c == ' ' or c == '\n' or c == '\r' or c == '\t') c = try in.takeByte();

    const negative = c == '-';
    if (negative) c = try in.takeByte();
    if (c < '0' or c > '9') return error.NotANumber;

    var value: i64 = 0;
    while (true) {
        value = value * 10 + (c - '0');
        c = in.takeByte() catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (c < '0' or c > '9') break;
    }
    return if (negative) -value else value;
}

/// One test case: the sum of the values and the largest of them.
///
/// The sum is `i64` on purpose. Three values of 10^9 add up to 3 * 10^9, and
/// `i32` stops at 2,147,483,647.
fn solve(in: *std.Io.Reader, out: *std.Io.Writer) !void {
    const n: usize = @intCast(try nextInt(in));
    if (n == 0 or n > max_n) return error.BadLength;

    const items = values[0..n];
    for (items) |*v| v.* = try nextInt(in);

    var sum: i64 = 0;
    var largest = items[0];
    for (items) |v| {
        sum += v;
        largest = @max(largest, v);
    }
    try out.print("{d} {d}\n", .{ sum, largest });
}

pub fn main(init: std.process.Init) !void {
    var in_buf: [64 * 1024]u8 = undefined;
    var stdin = std.Io.File.stdin().readerStreaming(init.io, &in_buf);
    const in = &stdin.interface;

    // Every answer goes into this buffer, and the operating system sees one
    // write each time it fills, not one per line.
    var out_buf: [64 * 1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &out_buf);
    const out = &stdout.interface;

    const cases = try nextInt(in);
    for (0..@intCast(cases)) |_| try solve(in, out);

    try out.flush();
}
