# Antialiasing

> Coverage is alpha. Sample the inside test sixteen times per pixel and the staircase goes away.

A pixel is not a point. It is a small square of the image, and a shape's edge
usually crosses it rather than landing neatly outside or inside. Testing only
the pixel's centre forces a yes-or-no answer to a question whose real answer
is a fraction. The staircase you see on every hard edge is that rounding error
made visible.

Ask the same question at sixteen points inside the pixel and the answer
becomes a count from 0 to 16. That count is **coverage**, and coverage is
exactly the alpha value to composite with.

```zig
const std = @import("std");
const canvas = @import("_canvas.zig");

var pixels: [canvas.width * canvas.height]u32 = undefined;

const samples = 4; // 4x4 = 16 tests per pixel

fn blendChannel(src: u8, dst: u8, a: u32) u8 {
    return @intCast((@as(u32, src) * a + @as(u32, dst) * (255 - a) + 127) / 255);
}

/// Coverage in 0..16: how many of the sub-positions inside this pixel fall
/// within the circle. Sub-positions sit at the centres of a 4x4 grid, offset
/// by half a sub-pixel, so the sampling is symmetric about the pixel centre.
///
/// Everything is scaled by `samples * 2` to stay in integers: a sub-position
/// is at an odd multiple of half a sub-pixel, so doubling makes it whole.
fn coverage(x: i32, y: i32, cx: i32, cy: i32, r: i32) u32 {
    const scale = samples * 2;
    const rs = r * scale;
    var hits: u32 = 0;
    var sy: i32 = 0;
    while (sy < samples) : (sy += 1) {
        var sx: i32 = 0;
        while (sx < samples) : (sx += 1) {
            const px = x * scale + 2 * sx + 1;
            const py = y * scale + 2 * sy + 1;
            const dx = px - (cx * scale + samples);
            const dy = py - (cy * scale + samples);
            if (dx * dx + dy * dy <= rs * rs) hits += 1;
        }
    }
    return hits;
}

fn hardCircle(cx: i32, cy: i32, r: i32, color: u32) void {
    var y = cy - r - 1;
    while (y <= cy + r + 1) : (y += 1) {
        var x = cx - r - 1;
        while (x <= cx + r + 1) : (x += 1) {
            const dx = x - cx;
            const dy = y - cy;
            if (dx * dx + dy * dy <= r * r) canvas.putPixel(&pixels, x, y, color);
        }
    }
}

fn smoothCircle(cx: i32, cy: i32, r: i32, color: u32) void {
    var y = cy - r - 1;
    while (y <= cy + r + 1) : (y += 1) {
        var x = cx - r - 1;
        while (x <= cx + r + 1) : (x += 1) {
            const hits = coverage(x, y, cx, cy, r);
            if (hits == 0) continue;
            if (x < 0 or y < 0) continue;
            const ux: usize = @intCast(x);
            const uy: usize = @intCast(y);
            if (ux >= canvas.width or uy >= canvas.height) continue;

            // 16 hits is fully inside; anything less is a partial pixel, and
            // the fraction is exactly the alpha to composite with.
            const alpha = (hits * 255) / (samples * samples);
            const i = uy * canvas.width + ux;
            const s = canvas.channels(color);
            const d = canvas.channels(pixels[i]);
            pixels[i] = canvas.rgb(
                blendChannel(s.r, d.r, alpha),
                blendChannel(s.g, d.g, alpha),
                blendChannel(s.b, d.b, alpha),
            );
        }
    }
}

pub fn main(init: std.process.Init) !void {
    var buf: [8192]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    canvas.fill(&pixels, canvas.rgb(0, 0, 30));

    const ink = canvas.rgb(255, 230, 150);
    hardCircle(16, 16, 12, ink);
    smoothCircle(47, 16, 12, ink);

    try canvas.dump(out, &pixels);

    try out.writeAll("\nleft: hard test. right: 16 samples per pixel.\n");
    try out.writeAll("\ncoverage across the right circle's edge, row y=16:\n");
    var x: i32 = 56;
    while (x <= 61) : (x += 1) {
        const hits = coverage(x, 16, 47, 16, 12);
        try out.print("  x={d}: {d:>2}/16 -> alpha {d:>3}\n", .{ x, hits, (hits * 255) / 16 });
    }

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`09-graphics.antialias`)*

The two circles are the same radius and the same colour. The left one uses the
hard test from [Circles](../circles/). The right one runs a 4x4 grid of
samples per pixel and blends by the fraction that passed. The printed table
walks across the right circle's edge on one row, where a pixel that is half
covered comes out at alpha 127.

## The arithmetic stays integer

Sub-positions sit at the centres of a 4x4 grid inside the pixel, which puts
them at odd multiples of half a sub-pixel. Multiplying every coordinate by `2
* samples` makes those whole numbers, so the distance test is the same
squared-integer comparison as before:

```zig
const scale = samples * 2;
const px = x * scale + 2 * sx + 1;
```

The `+ 1` is the half-sub-pixel offset. Sampling at the corners instead
(dropping it) biases the whole edge by half a pixel, which is small,
systematic, and visible when two antialiased shapes are meant to meet.

## What this costs

Sixteen inside tests per pixel, over a bounding box that has to grow by one
pixel on each side so partially covered pixels are not skipped. That is a real
cost, and it is why supersampling is the technique you reach for first and
replace later.

For a circle, the distance from the centre already tells you how far into the
edge a pixel is. A one-pixel-wide ramp on that distance gives a good edge in
one test. Signed distance fields generalize that idea to arbitrary shapes.
Analytic coverage for polygon edges is what a font rasterizer does, because
sampling text at this quality would be far too slow.

Supersampling has one advantage those do not: it needs no knowledge of the
shape. Any inside test at all, however it is written, becomes antialiased by
evaluating it more often. That makes it the right first move and a reasonable
permanent answer for offline rendering.

## Where the result is wrong

Blending happens in sRGB here, as it does everywhere else in this section. A
half-covered pixel therefore comes out darker than half the light of a covered
one, which makes thin antialiased strokes look thinner than they are. Text
rasterizers care about this a lot; see the note at the end of [Alpha
Blending](../blending/).

## Exercises

1. **Vary the sample count.** Drop to 2x2 and the ramp gets four levels instead
   of sixteen; the character dump makes the banding easy to count.
2. **Rotate the sample grid.** A regular grid resolves near-horizontal and
   near-vertical edges worst, which is why hardware uses rotated grid patterns.
   Offset the samples and compare the top of the circle.
3. **Antialias a line.** Xiaolin Wu's algorithm is Bresenham with the error term
   reused as coverage, which is this page's idea applied to
   [Lines](../lines/) with no extra sampling at all.
