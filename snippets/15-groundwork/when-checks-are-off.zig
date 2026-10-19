//! title: When the Checks Are Off
//! Operators with the same meaning in each build, and how to see your build.

const std = @import("std");
const builtin = @import("builtin");

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout_writer.interface;

    // Each program can see its build mode.
    try out.print("build mode: {t}\n", .{builtin.optimize});
    try out.print("safety checks present: {}\n\n", .{builtin.optimize.runtimeSafety()});

    var a: u8 = 200;
    var b: u8 = 100;
    _ = &a;
    _ = &b;

    // Four ways to say what must occur when 300 does not fit in a u8. None of
    // them change with the build mode, because none of them use a check that
    // a release build can remove.

    // 1. Wrap, on purpose.
    try out.print("a +% b            = {d}\n", .{a +% b});

    // 2. Refuse, with an error that the caller must handle.
    if (std.math.add(u8, a, b)) |sum| {
        try out.print("std.math.add      = {d}\n", .{sum});
    } else |err| {
        try out.print("std.math.add      = {t}\n", .{err});
    }

    // 3. Give the answer and a flag, with no error to handle.
    const result = @addWithOverflow(a, b);
    try out.print("@addWithOverflow  = {d}, overflowed: {d}\n", .{ result[0], result[1] });

    // 4. Saturate at the limit.
    try out.print("a +| b            = {d}\n", .{a +| b});

    try out.flush();
}
