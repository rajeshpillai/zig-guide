//! title: Vector Algebra
//! Dot, length, normalize, and cross on @Vector, so the math is data-parallel.
//! simd

const std = @import("std");

const Vec3 = @Vector(3, f32);

// Element-wise multiply, then a horizontal add. Works for any vector width,
// so `dot` is written once and reused by `length` below.
fn dot(a: Vec3, b: Vec3) f32 {
    return @reduce(.Add, a * b);
}

fn length(v: Vec3) f32 {
    return std.math.sqrt(dot(v, v));
}

// Divide every lane by the magnitude. `@splat` broadcasts the scalar length
// into a vector so the division is one SIMD op, not a loop.
fn normalize(v: Vec3) Vec3 {
    const len = length(v);
    if (len < 1e-6) return v; // a zero vector has no direction to keep
    const len_vec: Vec3 = @splat(len);
    return v / len_vec;
}

// Cross is the one operation that is genuinely 3D: it reads specific lanes,
// so it cannot be written width-generic like dot.
fn cross(a: Vec3, b: Vec3) Vec3 {
    return .{
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    };
}

fn printVec(out: anytype, v: Vec3) !void {
    try out.print("({d:.3}, {d:.3}, {d:.3})", .{ v[0], v[1], v[2] });
}

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    const a = Vec3{ 1.0, 0.0, 0.0 };
    const b = Vec3{ 0.5, 0.5, 0.0 };
    try out.print("dot     = {d:.3}\n", .{dot(a, b)});

    const v = Vec3{ 0.0, 3.0, 4.0 };
    try out.print("length  = {d:.3}\n", .{length(v)});

    const n = normalize(v);
    try out.writeAll("normal  = ");
    try printVec(out, n);
    try out.print(" (len {d:.3})\n", .{length(n)});

    // Right cross Up is Forward in a right-handed frame.
    const right = Vec3{ 1.0, 0.0, 0.0 };
    const up = Vec3{ 0.0, 1.0, 0.0 };
    try out.writeAll("cross   = ");
    try printVec(out, cross(right, up));
    try out.writeAll("\n");

    try out.flush();
}
