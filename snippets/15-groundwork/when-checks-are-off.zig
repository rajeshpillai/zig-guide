//! title: When the Checks Are Off
//! Operators that mean the same thing in every build, and how to see which build you are in.

const std = @import("std");
const builtin = @import("builtin");

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &stdout_writer.interface;

    // Every program can see how it was built.
    try out.print("build mode: {t}\n", .{builtin.mode});
    try out.print("safety checks present: {}\n\n", .{builtin.mode.runtimeSafety()});

    var a: u8 = 200;
    var b: u8 = 100;
    _ = &a;
    _ = &b;

    // Three ways of saying what should happen when 300 does not fit in a u8.
    // None of them change with the build mode, because none of them are
    // relying on a check that a release build is allowed to remove.

    // 1. Wrap, deliberately.
    try out.print("a +% b            = {d}\n", .{a +% b});

    // 2. Refuse, as an error the caller has to handle.
    if (std.math.add(u8, a, b)) |sum| {
        try out.print("std.math.add      = {d}\n", .{sum});
    } else |err| {
        try out.print("std.math.add      = {t}\n", .{err});
    }

    // 3. Answer and report, with no error handling at all.
    const result = @addWithOverflow(a, b);
    try out.print("@addWithOverflow  = {d}, overflowed: {d}\n", .{ result[0], result[1] });

    // 4. Saturate at the limit.
    try out.print("a +| b            = {d}\n", .{a +| b});

    try out.flush();
}
