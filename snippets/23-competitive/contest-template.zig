//! title: A Contest Template
//! native
//! The one program in this section that reads real stdin. Each other chapter
//! parses a const string through a `*std.Io.Reader`. This program gives the
//! same type of reader a file handle. CI gives it the sibling `.stdin` file
//! and compares stdout, in the same way as a judge.

const std = @import("std");

/// The largest `n` that the problem allows. Contest statements always give
/// this limit. If the storage size comes from the limit, the program does not
/// allocate memory.
const max_n = 200_000;

/// The declaration is at container level, not inside `main`.
///
/// 200,000 values of 8 bytes is 1.6 MB. A local array is on the stack. On
/// Linux the stack is usually 8 MB, and on a judge it is frequently smaller.
/// Thus a bound ten times larger crashes before the first read. A global is
/// in the zeroed data of the program, and each test case uses it again.
var values: [max_n]i64 = undefined;

/// Skip whitespace, then read one integer.
///
/// The function reads one byte at a time and does not examine line breaks.
/// Thus the layout of the input has no effect. A judge tells you the tokens
/// and their order, not the line of each token.
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

/// One test case: the sum of the values and the largest value.
///
/// The sum is `i64` on purpose. The sum of three values of 10^9 is 3 * 10^9,
/// and the maximum value of `i32` is 2,147,483,647.
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

    // Each answer goes into this buffer. The operating system gets one write
    // each time the buffer is full, not one write for each line.
    var out_buf: [64 * 1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(init.io, &out_buf);
    const out = &stdout.interface;

    const cases = try nextInt(in);
    for (0..@intCast(cases)) |_| try solve(in, out);

    try out.flush();
}
