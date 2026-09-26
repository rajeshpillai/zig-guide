//! title: Overflow Without Panics
//! Four deliberate ways to add two numbers that might not fit.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    // In a debug or safe build, plain `a + b` on these panics. A panic is the
    // right default for bugs. It is the wrong choice for untrusted input,
    // because bad input is an expected condition, not a programming error.
    const a: u8 = 200;
    const b: u8 = 100;

    // Option 1: an error you can handle. The usual choice at trust
    // boundaries, because the caller decides what "too big" means.
    if (std.math.add(u8, a, b)) |sum| {
        try out.print("std.math.add: {d}\n", .{sum});
    } else |err| {
        try out.print("std.math.add: {t}\n", .{err});
    }

    // Option 2: saturate. Clamps at the type's bounds. Use it for gain
    // controls, progress counters, and anything where "stay at max" makes sense.
    try out.print("saturating +|: {d}\n", .{a +| b});

    // Option 3: wrap. Modular arithmetic, stated in the operator. Use it for
    // hashes, checksums and ring buffer indices. Do not use it for quantities.
    try out.print("wrapping   +%: {d}\n", .{a +% b});

    // Option 4: an overflow bit you can check. Returns the wrapped result and a
    // flag, so you can branch without losing the low bits.
    const pair = @addWithOverflow(a, b);
    try out.print("@addWithOverflow: result={d} overflowed={d}\n", .{
        pair[0], pair[1],
    });

    // Same choices exist for subtraction and multiplication: std.math.sub
    // and mul, the -| and *| operators, -% and *%, and the builtins.
    try out.print("u8 floor stays a u8: {d}\n", .{@as(u8, 255) +| 1});

    try out.flush();
}
