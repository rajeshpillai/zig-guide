//! title: The std.math Toolbox
//! Trig, powers, roots, and a comparison of floats without ==.

const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    // The constants are in std.math.
    try out.print("pi = {d:.5}\n", .{std.math.pi});

    // Trig functions take radians. degreesToRadians does the conversion.
    const deg: f32 = 90.0;
    const rad = std.math.degreesToRadians(deg);
    try out.print("{d:.1} deg = {d:.4} rad\n", .{ deg, rad });
    try out.print("sin(90 deg) = {d:.4}\n", .{std.math.sin(rad)});
    try out.print("cos(0)      = {d:.4}\n", .{std.math.cos(@as(f32, 0.0))});

    // pow takes the type as its first argument. sqrt gets the type from its operand.
    try out.print("pow(2, 8)   = {d}\n", .{std.math.pow(f32, 2.0, 8.0)});
    try out.print("sqrt(64)    = {d}\n", .{std.math.sqrt(@as(f32, 64.0))});

    // Rounding, and two common helpers.
    try out.print("floor(2.7)  = {d}\n", .{std.math.floor(@as(f64, 2.7))});
    try out.print("ceil(2.1)   = {d}\n", .{std.math.ceil(@as(f64, 2.1))});
    try out.print("hypot(3, 4) = {d}\n", .{std.math.hypot(@as(f64, 3.0), 4.0)});

    // Never compare floats with ==. Use a tolerance. The floats chapter tells why.
    try out.print("approxEqAbs(0.3, 0.30001, 1e-3)? {}\n", .{
        std.math.approxEqAbs(f64, 0.3, 0.30001, 1e-3),
    });

    try out.flush();
}
