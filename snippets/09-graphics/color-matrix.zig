//! title: Colour Matrices
//! Grayscale, sepia and saturation look like three filters. They are one
//! filter: a 3x3 matrix multiplying the channel vector, which means a chain of
//! them can be multiplied into a single matrix before the image is touched.

const std = @import("std");
const canvas = @import("_canvas.zig");

var pixels: [canvas.width * canvas.height]u32 = undefined;
var scratch: [canvas.width * canvas.height]u32 = undefined;

/// Row-major, every entry scaled by 256. Fixed point rather than floats
/// because the input and output are bytes: carrying `f32` through would add a
/// conversion at each end to buy precision that the final `@intCast` throws
/// away.
const Matrix = [9]i32;

const scale = 256;

const identity: Matrix = .{
    scale, 0,     0,
    0,     scale, 0,
    0,     0,     scale,
};

/// Rec. 601 luma in all three rows: every output channel becomes the same
/// weighted average, which is grayscale. The weights are the ones
/// `canvas.luma` uses, and they sum to exactly 256.
const luma_matrix: Matrix = .{
    77, 150, 29,
    77, 150, 29,
    77, 150, 29,
};

/// The classic sepia matrix. Its rows sum to 346, 308 and 241 rather than 256,
/// which is not a mistake: sepia is meant to lift the image as well as tint it,
/// and the red row deliberately gains the most.
const sepia: Matrix = .{
    101, 197, 48,
    89,  176, 43,
    70,  137, 34,
};

/// Saturation is a straight line between grayscale and the original, extended
/// past both ends.
///
///     out = luma + s * (in - luma)
///
/// At `s = 0` that is the luma matrix; at `s = 256` the identity; above 256 it
/// extrapolates away from grey, which is what a saturation slider past 100%
/// does. Writing it as a matrix rather than as a special case is what lets it
/// compose with everything else here.
fn saturation(s: i32) Matrix {
    var m: Matrix = undefined;
    for (&m, identity, luma_matrix) |*out, i, l| {
        out.* = @divTrunc(s * i + (scale - s) * l, scale);
    }
    return m;
}

/// Matrix product, in the same fixed point. `compose(a, b)` applies `b` first.
fn compose(a: Matrix, b: Matrix) Matrix {
    var m: Matrix = undefined;
    for (0..3) |row| {
        for (0..3) |col| {
            var sum: i32 = 0;
            for (0..3) |k| sum += a[row * 3 + k] * b[k * 3 + col];
            m[row * 3 + col] = @divTrunc(sum, scale);
        }
    }
    return m;
}

fn transform(color: u32, m: Matrix) u32 {
    const c = canvas.channels(color);
    const r: i32 = c.r;
    const g: i32 = c.g;
    const b: i32 = c.b;
    return canvas.rgb(
        clamp8(@divTrunc(m[0] * r + m[1] * g + m[2] * b, scale)),
        clamp8(@divTrunc(m[3] * r + m[4] * g + m[5] * b, scale)),
        clamp8(@divTrunc(m[6] * r + m[7] * g + m[8] * b, scale)),
    );
}

fn clamp8(v: i32) u8 {
    return @intCast(std.math.clamp(v, 0, 255));
}

fn apply(buf: []u32, m: Matrix) void {
    for (buf) |*p| p.* = transform(p.*, m);
}

pub fn main(init: std.process.Init) !void {
    var buf: [16384]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    canvas.scene(&pixels);
    apply(&pixels, sepia);
    try out.writeAll("sepia:\n");
    try canvas.dump(out, &pixels);

    const samples = [_]struct { name: []const u8, color: u32 }{
        .{ .name = "red disc", .color = canvas.rgb(230, 40, 40) },
        .{ .name = "green disc", .color = canvas.rgb(40, 220, 90) },
        .{ .name = "yellow block", .color = canvas.rgb(255, 220, 60) },
    };
    const shown = [_]struct { name: []const u8, m: Matrix }{
        .{ .name = "identity", .m = identity },
        .{ .name = "sat 0", .m = saturation(0) },
        .{ .name = "sat 200%", .m = saturation(512) },
        .{ .name = "sepia", .m = sepia },
    };

    try out.writeAll("\n");
    for (samples) |s| {
        try out.print("{s:>13}:", .{s.name});
        for (shown) |t| {
            const c = canvas.channels(transform(s.color, t.m));
            try out.print("  {s} {d:>3},{d:>3},{d:>3}", .{ t.name, c.r, c.g, c.b });
        }
        try out.writeByte('\n');
    }

    // Saturation moves chroma without moving luma, because the weights that
    // build the grey it interpolates against are the same weights that measure
    // brightness. The dump of a saturated image is nearly identical to the dump
    // of the original, and that is the correct result rather than a bug in the
    // dump.
    try out.writeAll("\nluma under saturation (original, sat 0, sat 200%)\n");
    for (samples) |s| {
        try out.print("{s:>13}: {d:>3} {d:>3} {d:>3}\n", .{
            s.name,
            canvas.luma(s.color),
            canvas.luma(transform(s.color, saturation(0))),
            canvas.luma(transform(s.color, saturation(512))),
        });
    }

    // Composition, and its cost. Two passes round to a byte twice; the composed
    // matrix rounds once, in the matrix product instead. The results are close
    // but not identical, which is the difference from a lookup table: composing
    // point operations on 8-bit channels is exact, composing matrices is not.
    canvas.scene(&pixels);
    apply(&pixels, saturation(160));
    apply(&pixels, sepia);

    canvas.scene(&scratch);
    apply(&scratch, compose(sepia, saturation(160)));

    var worst: i32 = 0;
    var differing: usize = 0;
    for (pixels, scratch) |a, b| {
        const ca = canvas.channels(a);
        const cb = canvas.channels(b);
        const d = @max(
            @abs(@as(i32, ca.r) - @as(i32, cb.r)),
            @max(@abs(@as(i32, ca.g) - @as(i32, cb.g)), @abs(@as(i32, ca.b) - @as(i32, cb.b))),
        );
        if (d > 0) differing += 1;
        worst = @max(worst, @as(i32, @intCast(d)));
    }
    try out.print(
        "\ntwo passes vs one composed matrix: {d} of {d} pixels differ, by at most {d}\n",
        .{ differing, pixels.len, worst },
    );

    const composed = compose(sepia, saturation(160));
    try out.writeAll("\nsepia . saturation(62%) =\n");
    for (0..3) |row| {
        try out.print("  {d:>4} {d:>4} {d:>4}\n", .{
            composed[row * 3], composed[row * 3 + 1], composed[row * 3 + 2],
        });
    }

    try out.flush();
}
