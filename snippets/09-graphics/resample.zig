//! title: Scaling and Resampling
//! Every filter so far kept the grid it was given. Change the grid and the
//! output pixels stop lining up with input pixels, which raises the question
//! every resampler answers differently: what is the colour at a point that is
//! not a pixel?

const std = @import("std");
const canvas = @import("_canvas.zig");

var pixels: [canvas.width * canvas.height]u32 = undefined;

/// Coordinates are in 16.16 fixed point: 16 bits of pixel index and 16 bits of
/// position inside the pixel. Integers throughout keeps this exactly
/// reproducible, which matters more here than anywhere else in the section
/// because a resampler that rounds differently on two machines produces
/// different files.
const frac_bits = 16;
const one = 1 << frac_bits;

const Image = struct {
    pixels: []const u32,
    width: usize,
    height: usize,

    fn at(self: Image, x: i64, y: i64) u32 {
        const cx: usize = @intCast(std.math.clamp(x, 0, @as(i64, @intCast(self.width)) - 1));
        const cy: usize = @intCast(std.math.clamp(y, 0, @as(i64, @intCast(self.height)) - 1));
        return self.pixels[cy * self.width + cx];
    }
};

/// Nearest neighbour: round the sample position to the closest pixel centre.
fn nearest(src: Image, fx: i64, fy: i64) u32 {
    return src.at((fx + one / 2) >> frac_bits, (fy + one / 2) >> frac_bits);
}

/// Bilinear: the four surrounding pixels, weighted by how close the sample
/// point is to each.
fn bilinear(src: Image, fx: i64, fy: i64) u32 {
    // Sample positions are relative to pixel *centres*, so shift back by half a
    // pixel before splitting into index and fraction.
    const px = fx - one / 2;
    const py = fy - one / 2;
    const x0 = px >> frac_bits;
    const y0 = py >> frac_bits;
    const tx = px & (one - 1);
    const ty = py & (one - 1);

    const c00 = canvas.channels(src.at(x0, y0));
    const c10 = canvas.channels(src.at(x0 + 1, y0));
    const c01 = canvas.channels(src.at(x0, y0 + 1));
    const c11 = canvas.channels(src.at(x0 + 1, y0 + 1));

    return canvas.rgb(
        mix4(c00.r, c10.r, c01.r, c11.r, tx, ty),
        mix4(c00.g, c10.g, c01.g, c11.g, tx, ty),
        mix4(c00.b, c10.b, c01.b, c11.b, tx, ty),
    );
}

fn mix4(a: u8, b: u8, c: u8, d: u8, tx: i64, ty: i64) u8 {
    const top = @as(i64, a) * (one - tx) + @as(i64, b) * tx;
    const bottom = @as(i64, c) * (one - tx) + @as(i64, d) * tx;
    const value = (top * (one - ty) + bottom * ty) >> (frac_bits * 2);
    return @intCast(std.math.clamp(value, 0, 255));
}

/// Box filter: average every source pixel that falls inside the output pixel.
/// For downscaling this is the one that is actually correct, because it looks
/// at all the input rather than a sample of it.
fn box(src: Image, dst_x: usize, dst_y: usize, dst_w: usize, dst_h: usize) u32 {
    const x_start = (dst_x * src.width) / dst_w;
    const x_end = @max(x_start + 1, ((dst_x + 1) * src.width) / dst_w);
    const y_start = (dst_y * src.height) / dst_h;
    const y_end = @max(y_start + 1, ((dst_y + 1) * src.height) / dst_h);

    var r: u32 = 0;
    var g: u32 = 0;
    var b: u32 = 0;
    var n: u32 = 0;
    for (y_start..y_end) |y| {
        for (x_start..x_end) |x| {
            const c = canvas.channels(src.at(@intCast(x), @intCast(y)));
            r += c.r;
            g += c.g;
            b += c.b;
            n += 1;
        }
    }
    return canvas.rgb(@intCast(r / n), @intCast(g / n), @intCast(b / n));
}

const Sampler = enum { nearest, bilinear, box };

/// Resample `src` into a `dst_w` x `dst_h` buffer.
///
/// The mapping is the part that goes wrong. An output pixel covers a range of
/// the input, and the point to sample is the *centre* of that range:
///
///     src = (dst + 0.5) * scale - 0.5
///
/// Dropping either half-pixel gives `src = dst * scale`, which lines the two
/// images up by their top-left corners instead of their centres and shifts the
/// result by half a source pixel. That is the single most common resampling
/// bug, and on a 2x upscale it is a visible offset.
fn resample(
    dst: []u32,
    dst_w: usize,
    dst_h: usize,
    src: Image,
    sampler: Sampler,
    correct_centres: bool,
) void {
    const x_scale = @divTrunc(@as(i64, @intCast(src.width)) << frac_bits, @as(i64, @intCast(dst_w)));
    const y_scale = @divTrunc(@as(i64, @intCast(src.height)) << frac_bits, @as(i64, @intCast(dst_h)));

    for (0..dst_h) |y| {
        for (0..dst_w) |x| {
            if (sampler == .box) {
                dst[y * dst_w + x] = box(src, x, y, dst_w, dst_h);
                continue;
            }
            const fx = if (correct_centres)
                (((@as(i64, @intCast(x)) << frac_bits) + one / 2) * x_scale >> frac_bits) - one / 2
            else
                @as(i64, @intCast(x)) * x_scale;
            const fy = if (correct_centres)
                (((@as(i64, @intCast(y)) << frac_bits) + one / 2) * y_scale >> frac_bits) - one / 2
            else
                @as(i64, @intCast(y)) * y_scale;

            dst[y * dst_w + x] = switch (sampler) {
                .nearest => nearest(src, fx, fy),
                .bilinear => bilinear(src, fx, fy),
                .box => unreachable,
            };
        }
    }
}

/// Print a small buffer as luma values, since at these sizes the ASCII dump has
/// nothing to show.
fn printGrid(out: *std.Io.Writer, buf: []const u32, w: usize, h: usize) !void {
    for (0..h) |y| {
        try out.writeAll("   ");
        for (0..w) |x| try out.print("{d:>4}", .{canvas.luma(buf[y * w + x])});
        try out.writeByte('\n');
    }
}

pub fn main(init: std.process.Init) !void {
    var buf: [32768]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    canvas.scene(&pixels);
    const src = Image{ .pixels = &pixels, .width = canvas.width, .height = canvas.height };

    // A 4x1 strip upscaled to 8x1, so every number can be checked by hand.
    // Source luma: two dark, two bright.
    var strip = [_]u32{
        canvas.rgb(0, 0, 0),
        canvas.rgb(0, 0, 0),
        canvas.rgb(255, 255, 255),
        canvas.rgb(255, 255, 255),
    };
    const strip_src = Image{ .pixels = &strip, .width = 4, .height = 1 };
    var up: [8]u32 = undefined;

    try out.writeAll("4 pixels -> 8, source luma 0 0 255 255\n");
    resample(&up, 8, 1, strip_src, .nearest, true);
    try out.writeAll("  nearest, centres correct:\n");
    try printGrid(out, &up, 8, 1);
    resample(&up, 8, 1, strip_src, .bilinear, true);
    try out.writeAll("  bilinear, centres correct:\n");
    try printGrid(out, &up, 8, 1);
    resample(&up, 8, 1, strip_src, .bilinear, false);
    try out.writeAll("  bilinear, half-pixel bug (note the shift):\n");
    try printGrid(out, &up, 8, 1);

    // Downscale the scene to a quarter of its size, three ways.
    const small_w = canvas.width / 4;
    const small_h = canvas.height / 4;
    var small: [(canvas.width / 4) * (canvas.height / 4)]u32 = undefined;

    resample(&small, small_w, small_h, src, .nearest, true);
    try out.writeAll("\n64x32 -> 16x8, nearest:\n");
    try printGrid(out, &small, small_w, small_h);

    resample(&small, small_w, small_h, src, .box, true);
    try out.writeAll("\n64x32 -> 16x8, box filtered:\n");
    try printGrid(out, &small, small_w, small_h);

    // Aliasing, with nowhere to hide. A row of alternating black and white
    // columns has a real average of 127 everywhere. Nearest neighbour samples
    // every fourth pixel, and every fourth pixel of an alternating pattern is
    // the *same* colour, so the answer is a solid bar of whichever phase the
    // grid happened to land on. The detail is not merely lost; it has become a
    // large, confident, wrong feature.
    var stripes: [64]u32 = undefined;
    for (&stripes, 0..) |*p, i| {
        p.* = if (i % 2 == 0) canvas.rgb(0, 0, 0) else canvas.rgb(255, 255, 255);
    }
    const stripe_src = Image{ .pixels = &stripes, .width = 64, .height = 1 };
    var thin: [16]u32 = undefined;

    try out.writeAll("\nalternating black/white columns, 64 -> 16 (true average is 127)\n");
    resample(&thin, 16, 1, stripe_src, .nearest, true);
    try out.writeAll("  nearest:\n");
    try printGrid(out, &thin, 16, 1);
    resample(&thin, 16, 1, stripe_src, .box, true);
    try out.writeAll("  box filtered:\n");
    try printGrid(out, &thin, 16, 1);

    try out.flush();
}
