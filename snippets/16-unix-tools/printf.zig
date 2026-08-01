//! title: printf
//! Turning a number into text, digit by digit, backwards.

const std = @import("std");

/// Write `value` as decimal into `buf`, returning the part used.
///
/// The digits come out in reverse because the only cheap way to get one is
/// `value % 10`, which hands you the *last* one. So they are written into the
/// end of the buffer and the slice is taken from where you stopped.
fn decimal(buf: []u8, value: i64) []const u8 {
    if (value == 0) {
        buf[0] = '0';
        return buf[0..1];
    }

    const negative = value < 0;
    // Negate in a wider type. On the most negative i64 there is no positive
    // counterpart, so `-value` in the same type is an overflow, and this is
    // the trap every hand-written printf has fallen into at least once.
    var n: u64 = if (negative) @as(u64, @intCast(-@as(i128, value))) else @intCast(value);

    var i = buf.len;
    while (n > 0) {
        i -= 1;
        buf[i] = '0' + @as(u8, @intCast(n % 10));
        n /= 10;
    }
    if (negative) {
        i -= 1;
        buf[i] = '-';
    }
    return buf[i..];
}

/// The scanner: copy bytes through until '%', then dispatch on the next one.
fn format(out: *std.Io.Writer, comptime fmt: []const u8, args: []const i64) !void {
    var arg: usize = 0;
    var i: usize = 0;
    while (i < fmt.len) : (i += 1) {
        if (fmt[i] != '%') {
            try out.writeByte(fmt[i]);
            continue;
        }
        i += 1;
        if (i == fmt.len) break;
        switch (fmt[i]) {
            'd' => {
                var digits: [24]u8 = undefined;
                try out.writeAll(decimal(&digits, args[arg]));
                arg += 1;
            },
            // %% is how you print the character the scanner is looking for.
            '%' => try out.writeByte('%'),
            else => {
                // Unknown specifier: print it back rather than guessing.
                try out.writeByte('%');
                try out.writeByte(fmt[i]);
            },
        }
    }
}

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout_writer.interface;

    var digits: [24]u8 = undefined;
    for ([_]i64{ 0, 7, 42, -1, 1234567890, std.math.minInt(i64) }) |n| {
        try out.print("{s}\n", .{decimal(&digits, n)});
    }
    try out.writeAll("\n");

    try format(out, "%d + %d = %d\n", &.{ 2, 3, 5 });
    try format(out, "100%% of %d\n", &.{7});
    try format(out, "unknown %q stays put\n", &.{});

    try out.flush();
}
