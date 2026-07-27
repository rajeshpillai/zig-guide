//! title: Convolution
//! A kernel is a small matrix slid over the image. Every blur, sharpen and edge
//! detector on this page is the same loop with different numbers in it, and the
//! two things that go wrong are always the same two.

const std = @import("std");
const canvas = @import("_canvas.zig");

const count = canvas.width * canvas.height;

var pixels: [count]u32 = undefined;
var scratch: [count]u32 = undefined;

/// A square kernel of odd side length, with the divisor its weights sum to.
///
/// `Kernel(3)` and `Kernel(5)` are distinct types produced by a type function,
/// so the side length is a compile-time constant inside `convolve` and the
/// inner loops unroll against a known bound.
fn Kernel(comptime side: usize) type {
    comptime std.debug.assert(side % 2 == 1);
    return struct {
        weights: [side * side]i32,
        divisor: i32,

        const radius: i32 = @intCast(side / 2);
    };
}

/// Sample a pixel, clamping out-of-range coordinates to the edge.
///
/// Something has to happen at the border, where part of the kernel hangs off
/// the image. Returning black there draws a dark frame around every blurred
/// image; wrapping to the far side bleeds the top into the bottom. Clamping
/// repeats the edge pixel, which is invisible and is what most image libraries
/// do by default.
fn sample(src: []const u32, x: i32, y: i32) u32 {
    const cx = std.math.clamp(x, 0, @as(i32, @intCast(canvas.width)) - 1);
    const cy = std.math.clamp(y, 0, @as(i32, @intCast(canvas.height)) - 1);
    return src[@as(usize, @intCast(cy)) * canvas.width + @as(usize, @intCast(cx))];
}

/// The loop. `dst` and `src` must not be the same buffer: a convolution reads
/// neighbours, so writing an output pixel back over its input corrupts the
/// input of every pixel still to come. That bug looks like a directional smear
/// rather than a crash, which is why it survives so long in hand-written code.
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

/// Weights sum to 16, so the divisor is 16 and the image keeps its brightness.
/// A kernel whose weights do not sum to its divisor darkens or brightens the
/// whole image, which is almost never what was intended.
const gaussian3 = Kernel(3){
    .weights = .{
        1, 2, 1,
        2, 4, 2,
        1, 2, 1,
    },
    .divisor = 16,
};

/// Weights sum to 1: the centre is boosted and its neighbours are subtracted,
/// so flat areas come out unchanged and edges are exaggerated.
const sharpen3 = Kernel(3){
    .weights = .{
        0,  -1, 0,
        -1, 5,  -1,
        0,  -1, 0,
    },
    .divisor = 1,
};

/// Sobel's two halves. Each sums to zero, so a flat area produces zero: these
/// measure change, not brightness, and the output is a gradient rather than an
/// image.
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

/// Edge strength: run both kernels on luma and combine them.
///
/// The exact magnitude is `sqrt(gx*gx + gy*gy)`. `|gx| + |gy|` overestimates it
/// by up to 41% on diagonals and needs no square root, which is the trade the
/// original hardware implementations made and most still do.
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
            // width, so the sum comes back to `i32` before the divide.
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

    // Three blur passes. Repeating a 3x3 gaussian approximates a wider one, and
    // costs three cheap passes instead of one expensive 7x7.
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

    // What the two kernels answer at three points. The block's corner has a
    // gradient in both directions; its flat interior has none.
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
        // The sign of `gx` is the direction of the change: positive where the
        // image gets brighter to the right. Zig prints it whenever a width is
        // given, which here says something worth reading.
        try out.print("{s:>16} | {d:>5} {d:>5} {d:>9}\n", .{ p.name, gx, gy, @abs(gx) + @abs(gy) });
    }

    // Sharpen across the block's left edge. A sharpen kernel does not add
    // detail: it exaggerates the difference it already found, which on a hard
    // edge means the dark side goes darker and the bright side brighter than
    // either was. That overshoot is ringing, and it is the artifact every
    // sharpen slider trades against.
    canvas.scene(&pixels);
    convolve(3, &scratch, &pixels, sharpen3);
    try out.writeAll("\nluma along y=10, x=5..12\n     x |");
    for (5..13) |x| try out.print(" {d:>4}", .{x});
    try out.writeAll("\n  orig |");
    for (5..13) |x| try out.print(" {d:>4}", .{canvas.luma(pixels[10 * canvas.width + x])});
    try out.writeAll("\n sharp |");
    for (5..13) |x| try out.print(" {d:>4}", .{canvas.luma(scratch[10 * canvas.width + x])});
    try out.writeByte('\n');

    // The in-place bug, made visible. Both start from the same picture; one
    // writes into its own input. (9,7) is the block's top-left corner, where
    // the already-blurred row above leaks into the answer.
    const probe = 7 * canvas.width + 9;

    canvas.scene(&pixels);
    convolve(3, &scratch, &pixels, gaussian3);
    const c = canvas.channels(scratch[probe]);

    canvas.scene(&pixels);
    convolve(3, &pixels, &pixels, gaussian3); // same buffer for src and dst
    const w = canvas.channels(pixels[probe]);

    try out.print("\npixel (9,7) into a second buffer: {d} {d} {d}\n", .{ c.r, c.g, c.b });
    try out.print("pixel (9,7) in place:             {d} {d} {d}\n", .{ w.r, w.g, w.b });

    // A separable kernel run as two 1D passes. 3x3 costs 9 multiplies per
    // pixel; a horizontal pass then a vertical one costs 6, and the gap widens
    // with the square of the kernel side. The results agree to within the
    // rounding of the extra divide, not exactly. Sampled in the gradient, where
    // there is a fraction to lose: inside the saturated block both round to the
    // same byte and the difference is invisible.
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
