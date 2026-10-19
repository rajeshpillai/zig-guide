//! title: Convolution
//! A kernel is a small matrix that moves over the image. Each blur, sharpen
//! and edge detector on this page is the same loop with different numbers.
//! The two common errors are always the same two errors.

const std = @import("std");
const canvas = @import("_canvas.zig");

const count = canvas.width * canvas.height;

var pixels: [count]u32 = undefined;
var scratch: [count]u32 = undefined;

/// A square kernel with an odd side length. The divisor is the sum of its
/// weights.
///
/// `Kernel(3)` and `Kernel(5)` are different types from a type function.
/// Thus the side length is a compile-time constant inside `convolve`, and the
/// inner loops unroll against a known bound.
fn Kernel(comptime side: usize) type {
    comptime std.debug.assert(side % 2 == 1);
    return struct {
        weights: [side * side]i32,
        divisor: i32,

        const radius: i32 = @intCast(side / 2);
    };
}

/// Sample a pixel. Clamp coordinates outside the image to the edge.
///
/// At the border, part of the kernel is outside the image, and the code must
/// do something there. If the code returns black, each blurred image gets a
/// dark frame. If the code wraps to the far side, the top mixes into the
/// bottom. A clamp repeats the edge pixel. You cannot see the clamp, and most
/// image libraries use it by default.
fn sample(src: []const u32, x: i32, y: i32) u32 {
    const cx = std.math.clamp(x, 0, @as(i32, @intCast(canvas.width)) - 1);
    const cy = std.math.clamp(y, 0, @as(i32, @intCast(canvas.height)) - 1);
    return src[@as(usize, @intCast(cy)) * canvas.width + @as(usize, @intCast(cx))];
}

/// The loop. `dst` and `src` must not be the same buffer. A convolution reads
/// neighbours. If the loop writes an output pixel over its input, it corrupts
/// the input of each pixel that comes after it. The bug causes a smear in one
/// direction, not a crash. Thus the bug can stay hidden in hand-written code.
fn convolve(comptime side: usize, dst: []u32, src: []const u32, k: Kernel(side)) void {
    const K = Kernel(side);
    for (0..canvas.height) |y| {
        for (0..canvas.width) |x| {
            var r: i32 = 0;
            var g: i32 = 0;
            var b: i32 = 0;
            for (0..side) |ky| {
                for (0..side) |kx| {
                    const w = k.weights[ky * side + kx];
                    if (w == 0) continue;
                    const c = canvas.channels(sample(
                        src,
                        @as(i32, @intCast(x)) + @as(i32, @intCast(kx)) - K.radius,
                        @as(i32, @intCast(y)) + @as(i32, @intCast(ky)) - K.radius,
                    ));
                    r += w * c.r;
                    g += w * c.g;
                    b += w * c.b;
                }
            }
            dst[y * canvas.width + x] = canvas.rgb(
                clamp8(@divTrunc(r, k.divisor)),
                clamp8(@divTrunc(g, k.divisor)),
                clamp8(@divTrunc(b, k.divisor)),
            );
        }
    }
}

fn clamp8(v: i32) u8 {
    return @intCast(std.math.clamp(v, 0, 255));
}

/// The sum of the weights is 16. Thus the divisor is 16, and the image keeps
/// its brightness. If the sum of the weights is not equal to the divisor, the
/// kernel makes the full image darker or brighter. Usually that is a mistake.
const gaussian3 = Kernel(3){
    .weights = .{
        1, 2, 1,
        2, 4, 2,
        1, 2, 1,
    },
    .divisor = 16,
};

/// The sum of the weights is 1. The kernel increases the centre and subtracts
/// the neighbours. Thus flat areas do not change, and edges become stronger.
const sharpen3 = Kernel(3){
    .weights = .{
        0,  -1, 0,
        -1, 5,  -1,
        0,  -1, 0,
    },
    .divisor = 1,
};

/// The two halves of Sobel. The sum of each half is zero. Thus a flat area
/// gives zero. These kernels measure change, not brightness. The output is a
/// gradient, not an image.
const sobel_x = [9]i32{
    -1, 0, 1,
    -2, 0, 2,
    -1, 0, 1,
};
const sobel_y = [9]i32{
    -1, -2, -1,
    0,  0,  0,
    1,  2,  1,
};

/// Edge strength: run both kernels on luma, and add the two results.
///
/// The exact magnitude is `sqrt(gx*gx + gy*gy)`. On diagonals, `|gx| + |gy|`
/// is up to 41% too large, but it needs no square root. The original hardware
/// implementations used this approximation, and most implementations still do.
fn sobel(dst: []u32, src: []const u32) void {
    for (0..canvas.height) |y| {
        for (0..canvas.width) |x| {
            var gx: i32 = 0;
            var gy: i32 = 0;
            for (0..3) |ky| {
                for (0..3) |kx| {
                    const l: i32 = @intCast(canvas.luma(sample(
                        src,
                        @as(i32, @intCast(x + kx)) - 1,
                        @as(i32, @intCast(y + ky)) - 1,
                    )));
                    gx += sobel_x[ky * 3 + kx] * l;
                    gy += sobel_y[ky * 3 + kx] * l;
                }
            }
            // `@abs` on a signed integer returns the unsigned type of the same
            // width. Thus the code changes the sum to `i32` before the divide.
            const sum: i32 = @intCast(@abs(gx) + @abs(gy));
            const mag = clamp8(@divTrunc(sum, 2));
            dst[y * canvas.width + x] = canvas.rgb(mag, mag, mag);
        }
    }
}

pub fn main(init: std.process.Init) !void {
    var buf: [16384]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    canvas.scene(&pixels);

    // Three blur passes. Three passes of a 3x3 gaussian are approximately
    // equal to a wider gaussian. Three fast passes cost less than one 7x7.
    for (0..3) |_| {
        convolve(3, &scratch, &pixels, gaussian3);
        @memcpy(&pixels, &scratch);
    }
    try out.writeAll("gaussian 3x3, three passes:\n");
    try canvas.dump(out, &pixels);

    canvas.scene(&pixels);
    sobel(&scratch, &pixels);
    try out.writeAll("\nsobel magnitude:\n");
    try canvas.dump(out, &scratch);

    // The answers of the two kernels at three points. Each edge of the block
    // has a gradient in one direction. The flat interior has no gradient.
    try out.writeAll("\n           point |    gx    gy  |gx|+|gy|\n");
    const probes = [_]struct { name: []const u8, x: usize, y: usize }{
        .{ .name = "block interior", .x = 16, .y = 10 },
        .{ .name = "block left edge", .x = 8, .y = 10 },
        .{ .name = "block top edge", .x = 16, .y = 6 },
    };
    for (probes) |p| {
        var gx: i32 = 0;
        var gy: i32 = 0;
        for (0..3) |ky| {
            for (0..3) |kx| {
                const l: i32 = @intCast(canvas.luma(sample(
                    &pixels,
                    @as(i32, @intCast(p.x + kx)) - 1,
                    @as(i32, @intCast(p.y + ky)) - 1,
                )));
                gx += sobel_x[ky * 3 + kx] * l;
                gy += sobel_y[ky * 3 + kx] * l;
            }
        }
        // The sign of `gx` is the direction of the change. The sign is
        // positive where the image becomes brighter to the right. When the
        // format has a width, Zig prints the sign. Here the sign is useful.
        try out.print("{s:>16} | {d:>5} {d:>5} {d:>9}\n", .{ p.name, gx, gy, @abs(gx) + @abs(gy) });
    }

    // Sharpen across the left edge of the block. A sharpen kernel does not
    // add detail. It makes the difference that it finds larger. On a hard
    // edge, the dark side becomes darker and the bright side becomes brighter
    // than before. This overshoot has the name ringing. Each sharpen slider
    // must balance more sharpness against more ringing.
    canvas.scene(&pixels);
    convolve(3, &scratch, &pixels, sharpen3);
    try out.writeAll("\nluma along y=10, x=5..12\n     x |");
    for (5..13) |x| try out.print(" {d:>4}", .{x});
    try out.writeAll("\n  orig |");
    for (5..13) |x| try out.print(" {d:>4}", .{canvas.luma(pixels[10 * canvas.width + x])});
    try out.writeAll("\n sharp |");
    for (5..13) |x| try out.print(" {d:>4}", .{canvas.luma(scratch[10 * canvas.width + x])});
    try out.writeByte('\n');

    // The in-place bug, in a form that you can see. Both versions start from
    // the same picture. One version writes into its own input. (9,7) is the
    // top-left corner of the block. There, the blurred row above it gets into
    // the answer.
    const probe = 7 * canvas.width + 9;

    canvas.scene(&pixels);
    convolve(3, &scratch, &pixels, gaussian3);
    const c = canvas.channels(scratch[probe]);

    canvas.scene(&pixels);
    convolve(3, &pixels, &pixels, gaussian3); // same buffer for src and dst
    const w = canvas.channels(pixels[probe]);

    try out.print("\npixel (9,7) into a second buffer: {d} {d} {d}\n", .{ c.r, c.g, c.b });
    try out.print("pixel (9,7) in place:             {d} {d} {d}\n", .{ w.r, w.g, w.b });

    // A separable kernel as two 1D passes. A 3x3 kernel costs 9 multiplies
    // for each pixel. A horizontal pass and then a vertical pass cost 6. The
    // difference increases with the square of the kernel side.
    //
    // The results are not exactly equal, because of the rounding of the extra
    // divide. The sample is in the gradient, where the rounding can lose a
    // fraction. Inside the saturated block, both versions round to the same
    // byte, and you cannot see the difference.
    const ramp_probe = 20 * canvas.width + 40;

    canvas.scene(&pixels);
    convolve(3, &scratch, &pixels, gaussian3);
    const t = canvas.channels(scratch[ramp_probe]);

    canvas.scene(&pixels);
    convolve(3, &scratch, &pixels, .{ .weights = .{ 0, 0, 0, 1, 2, 1, 0, 0, 0 }, .divisor = 4 });
    convolve(3, &pixels, &scratch, .{ .weights = .{ 0, 1, 0, 0, 2, 0, 0, 1, 0 }, .divisor = 4 });
    const s = canvas.channels(pixels[ramp_probe]);

    try out.print("\npixel (40,20) 3x3 in one pass: {d} {d} {d}\n", .{ t.r, t.g, t.b });
    try out.print("pixel (40,20) as two 1D passes: {d} {d} {d}\n", .{ s.r, s.g, s.b });

    try out.flush();
}
