//! title: Overflow Without Panics
//! Four explicit ways to add two numbers when the sum can be too large.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    // In a debug or safe build, plain `a + b` on these values panics. A panic
    // is the correct default for bugs. It is wrong for untrusted input,
    // because bad input is an expected condition, not a programming error.
    const a: u8 = 200;
    const b: u8 = 100;

    // Option 1: an error that you can handle. Use it at trust boundaries,
    // because there the caller decides what "too large" means.
    if (std.math.add(u8, a, b)) |sum| {
        try out.print("std.math.add: {d}\n", .{sum});
    } else |err| {
        try out.print("std.math.add: {t}\n", .{err});
    }

    // Option 2: saturate. The value stops at the limits of the type. Use it
    // for gain controls, progress counters, and all values that must stay at max.
    try out.print("saturating +|: {d}\n", .{a +| b});

    // Option 3: wrap. The operator tells that the arithmetic is modular. Use it
    // for hashes, checksums and ring buffer indices. Do not use it for quantities.
    try out.print("wrapping   +%: {d}\n", .{a +% b});

    // Option 4: an overflow bit that you can check. It returns the wrapped
    // result and a flag. Thus you can branch, and you keep the low bits.
    const pair = @addWithOverflow(a, b);
    try out.print("@addWithOverflow: result={d} overflowed={d}\n", .{
        pair[0], pair[1],
    });

    // Subtraction and multiplication have the same options: std.math.sub
    // and mul, the -| and *| operators, -% and *%, and the builtins.
    try out.print("u8 floor stays a u8: {d}\n", .{@as(u8, 255) +| 1});

    try out.flush();
}
