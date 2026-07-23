//! title: A SIMD Dot Product
//! @Vector processes lanes in parallel; the tail stays scalar.

const std = @import("std");

const Lanes = 4;
const V = @Vector(Lanes, i32);

fn dotScalar(xs: []const i32, ys: []const i32) i64 {
    var total: i64 = 0;
    for (xs, ys) |x, y| total += @as(i64, x) * y;
    return total;
}

fn dotSimd(xs: []const i32, ys: []const i32) i64 {
    var acc: V = @splat(0);
    var i: usize = 0;
    // Whole vectors first. The slice-to-array cast `[0..Lanes].*` is what
    // turns Lanes contiguous elements into vector operands.
    while (i + Lanes <= xs.len) : (i += Lanes) {
        const x: V = xs[i..][0..Lanes].*;
        const y: V = ys[i..][0..Lanes].*;
        acc += x * y; // one multiply and one add across all lanes
    }
    // Horizontal step: collapse the lanes into one number.
    var total: i64 = @reduce(.Add, acc);
    // The tail. A length that is not a multiple of Lanes leaves up to
    // Lanes - 1 elements; finish them the boring way.
    while (i < xs.len) : (i += 1) total += @as(i64, xs[i]) * ys[i];
    return total;
}

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    // 10 elements: two full vectors of 4, plus a tail of 2.
    var xs: [10]i32 = undefined;
    var ys: [10]i32 = undefined;
    for (&xs, &ys, 0..) |*x, *y, i| {
        x.* = @intCast(i + 1);
        y.* = @intCast((i + 1) * 2);
    }

    const scalar = dotScalar(&xs, &ys);
    const simd = dotSimd(&xs, &ys);

    try out.print("scalar: {d}\n", .{scalar});
    try out.print("simd:   {d}\n", .{simd});
    try out.print("equal:  {}\n", .{scalar == simd});

    try out.flush();
}
