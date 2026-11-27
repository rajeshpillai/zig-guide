# Scale and Resample

> Nearest, bilinear and box filters, the half-pixel bug, and why a downscale without a filter makes fine detail into a solid bar.

Each of the earlier filters kept the grid that it got: one output pixel for one
input pixel, at the same position. A change in size breaks this rule. The
output pixels do not align with the input pixels. Thus you must decide the
colour at a position between pixels.

```zig
const std = @import("std");
const canvas = @import("_canvas.zig");

var pixels: [canvas.width * canvas.height]u32 = undefined;

/// Coordinates are in 16.16 fixed point: 16 bits of pixel index and 16 bits of
/// position inside the pixel. Integers in all of the arithmetic make the result
/// exactly the same on each machine. This is more important here than in the
/// rest of the section. If a resampler rounds differently on two machines, it
/// makes different files.
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

/// Nearest neighbour: round the sample position to the nearest pixel centre.
fn nearest(src: Image, fx: i64, fy: i64) u32 {
    return src.at((fx + one / 2) >> frac_bits, (fy + one / 2) >> frac_bits);
}

/// Bilinear: the four pixels around the sample point. The weight of each pixel
/// comes from its distance to the sample point.
fn bilinear(src: Image, fx: i64, fy: i64) u32 {
    // Sample positions are relative to pixel *centres*. Thus move back by half a
    // pixel, then split the position into an index and a fraction.
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

/// Box filter: average each source pixel inside the output pixel. For a
/// downscale, the box filter is the correct filter, because it reads all of the
/// input and not only a sample of the input.
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
/// The mapping is where mistakes occur. An output pixel covers a range of the
/// input, and the point to sample is the *centre* of that range:
///
///     src = (dst + 0.5) * scale - 0.5
///
/// If you remove the two half-pixels, you get `src = dst * scale`. This formula
/// aligns the centres of the first pixels, not the corners of the images. The
/// result moves by `0.5 * (1 - scale)` source pixels. This is a common
/// resampling bug, and on a 2x upscale the offset is visible.
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
                ((((@as(i64, @intCast(x)) << frac_bits) + one / 2) * x_scale) >> frac_bits) - one / 2
            else
                @as(i64, @intCast(x)) * x_scale;
            const fy = if (correct_centres)
                ((((@as(i64, @intCast(y)) << frac_bits) + one / 2) * y_scale) >> frac_bits) - one / 2
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

/// Print a small buffer as luma values, because at these sizes the ASCII dump
/// shows nothing useful.
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

    // Upscale a 4x1 strip to 8x1. Then you can check each number by hand.
    // Source luma: two dark pixels, two bright pixels.
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

    // Downscale the scene to a quarter of its size, with two methods.
    const small_w = canvas.width / 4;
    const small_h = canvas.height / 4;
    var small: [(canvas.width / 4) * (canvas.height / 4)]u32 = undefined;

    resample(&small, small_w, small_h, src, .nearest, true);
    try out.writeAll("\n64x32 -> 16x8, nearest:\n");
    try printGrid(out, &small, small_w, small_h);

    resample(&small, small_w, small_h, src, .box, true);
    try out.writeAll("\n64x32 -> 16x8, box filtered:\n");
    try printGrid(out, &small, small_w, small_h);

    // A clear example of aliasing. A row of black and white columns that
    // alternate has a real average of 127 at each position. Nearest neighbour
    // samples each fourth pixel. In a pattern that alternates, each fourth
    // pixel has the *same* colour. Thus the result is a solid bar, in the
    // colour of the phase where the grid starts. The program loses the detail,
    // and a large wrong feature replaces it.
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
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`09-graphics.resample`)*

## The mapping, and the bug in it

An output pixel covers a range of the input. The point to sample is the centre
of that range:

```
src = (dst + 0.5) * scale - 0.5
```

The two halves are both necessary:

- `dst + 0.5` moves from the index of the output pixel to its centre.
- `- 0.5` moves from the centre in the input back to the index.

If you remove the two halves, you get `src = dst * scale`. This formula aligns
the centres of the first pixels in the two grids, and not the corners of the
images. The result moves by `0.5 * (1 - scale)` source pixels.

The snippet upscales four pixels to eight, with and without the correction:

```
4 pixels -> 8, source luma 0 0 255 255
  bilinear, centres correct:
      0   0   0   0  63 191 255 255
  bilinear, half-pixel bug (note the shift):
      0   0   0   0 127 255 255 255
```

The correct version puts a symmetric ramp of two samples across the edge. The
version with the bug puts a ramp of one sample. The full image is half an
output pixel to the left of its correct position.

On a 2x upscale, this offset is visible, and it is a common resampling bug.
The bug is easy to write and difficult to see in one image. When you blend the
result with the original, the bug is immediately clear.

The code uses fixed point and not floats. If a resampler rounds differently on
two machines, it makes different files. A difference of one in the last bit is
sufficient to fail a checksum.

## Nearest and bilinear

**Nearest** rounds the sample position to the nearest pixel centre. It reads
one pixel per output pixel, does no arithmetic on colours, and keeps the exact
values. Thus it is the correct choice for these images:

- pixel art
- indexed colour
- each image with values that are labels and not measurements

A bilinear interpolation of a segmentation mask gives class 7.5, which is not
a class.

**Bilinear** reads the four pixels around the sample point. It gives a weight
to each pixel from its distance to the sample point. Bilinear is a true
interpolation. For a photograph, it is the method with the lowest cost that
does not look blocky after an upscale.

Bicubic reads 16 pixels and gives a slightly sharper result. Lanczos reads
more pixels. Each step reads more pixels and gives a smaller improvement.

## A downscale is a different problem

An upscale needs values between the values that you have. A downscale must
discard values. The method that discards them decides the result: a smaller
version of the picture, or a different picture.

The snippet shows this clearly. It downscales a row of black and white columns
that alternate, to a quarter of its width. The true average of that row is 127
at each position:

```
alternating black/white columns, 64 -> 16 (true average is 127)
  nearest:
      0   0   0   0   0   0   0   0   0   0   0   0   0   0   0   0
  box filtered:
    127 127 127 127 127 127 127 127 127 127 127 127 127 127 127 127
```

Nearest neighbour samples each fourth pixel. In a pattern that alternates, each
fourth pixel has the same colour. Thus the result is a solid black bar. Each
output pixel has the same error. If the grid starts one pixel to the side,
the result is a solid white bar.

This effect is aliasing. The input had detail finer than the output grid can
show. Point sampling changed that detail into a large false feature. It did
not lose the detail smoothly. The same effect makes a striped shirt flicker
on video, and makes a brick wall at a distance show moiré.

The solution is to remove the detail before the program discards the samples.
There are two methods:

- Average each input pixel inside the output pixel. This method is the box
  filter above.
- Blur first, and then point-sample.

With each method, the filter must read all of the input. A downscaler that
reads one pixel per output pixel ignores the other pixels. Thus its output can
have the error above.

## The relation to antialiasing

[Antialiasing](https://www.ziglang.in/learn/graphics/antialiasing/) took sixteen samples inside one
pixel. It changed a hard inside/outside test into a coverage fraction.
A resampler uses the same idea from the other direction. A pixel covers an
area. When a program uses the pixel as one point, the result is the staircase
in antialiasing and the solid bar on this page.

Two practical notes:

**Filter in linear light.** An average of sRGB bytes makes a downscaled image
darker than the correct result. The error is largest where the contrast is
highest. [Alpha blending](https://www.ziglang.in/learn/graphics/blending/) gives the same warning.
The error is most visible in a downscale. A checkerboard of black and white
averages to 127 in sRGB, and to approximately 187 in linear light.

**Premultiply alpha.** An interpolation of colours that have their own alpha,
without premultiplication, adds the colour of fully transparent pixels to the
result. Thus each edge gets a halo. The halo has the colour that the
transparent regions contained.
