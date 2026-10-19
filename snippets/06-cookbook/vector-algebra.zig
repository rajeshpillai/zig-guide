//! title: Vector Algebra
//! Dot, length, normalize and cross on @Vector. Thus the math is data-parallel.
//! simd

const std = @import("std");

const Vec3 = @Vector(3, f32);

// Multiply element by element, then do a horizontal add. The body works for
// all vector widths. `length` below uses `dot` again.
fn dot(a: Vec3, b: Vec3) f32 {
    return @reduce(.Add, a * b);
}

fn length(v: Vec3) f32 {
    return std.math.sqrt(dot(v, v));
}

// Divide each lane by the magnitude. `@splat` copies the scalar length into
// a vector. Thus the division is one SIMD operation, not a loop.
fn normalize(v: Vec3) Vec3 {
    const len = length(v);
    if (len < 1e-6) return v; // a zero vector has no direction
    const len_vec: Vec3 = @splat(len);
    return v / len_vec;
}

// Cross is the only operation here that works only in 3D. It reads specific
// lanes. Thus you cannot write it for all widths, as you can write dot.
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

    // In a right-handed frame, Right cross Up is Forward.
    const right = Vec3{ 1.0, 0.0, 0.0 };
    const up = Vec3{ 0.0, 1.0, 0.0 };
    try out.writeAll("cross   = ");
    try printVec(out, cross(right, up));
    try out.writeAll("\n");

    try out.flush();
}
