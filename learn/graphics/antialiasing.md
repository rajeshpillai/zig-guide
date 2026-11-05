# Antialiasing

> Coverage is alpha. Do the inside test sixteen times for each pixel, and the jagged edges disappear.

A pixel is not a point. A pixel is a small square of the image. The edge of a
shape usually crosses the square. Usually the square is not fully outside or
fully inside the shape.

A test at only the centre of the pixel gives a yes-or-no answer. But the real
answer is a fraction. The staircase on each hard edge is this rounding error,
and you can see it.

Do the same test at sixteen points inside the pixel. Then the answer is a
count from 0 to 16. This count is the **coverage**, and the coverage is
exactly the alpha value for the composite.

```zig
const std = @import("std");
const canvas = @import("_canvas.zig");

var pixels: [canvas.width * canvas.height]u32 = undefined;

const samples = 4; // 4x4 = 16 tests per pixel

fn blendChannel(src: u8, dst: u8, a: u32) u8 {
    return @intCast((@as(u32, src) * a + @as(u32, dst) * (255 - a) + 127) / 255);
}

/// Coverage in 0..16: the number of sub-positions inside this pixel that are
/// in the circle. The sub-positions are at the centres of a 4x4 grid, with an
/// offset of half a sub-pixel. Thus the samples are symmetric about the
/// centre of the pixel.
///
/// The code multiplies all values by `samples * 2` to keep integers. A
/// sub-position is at an odd multiple of half a sub-pixel. Thus two times
/// that value is a whole number.
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

            // 16 hits means fully inside. Fewer hits mean a partial pixel.
            // The fraction is exactly the alpha for the composite.
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

The two circles have the same radius and the same colour:

- The left circle uses the hard test from [Circles](../circles/).
- The right circle tests a 4x4 grid of samples in each pixel. It blends by
  the fraction of samples that passed.

The table in the output goes across the edge of the right circle on one row.
A pixel that is half covered gets alpha 127.

## The arithmetic stays integer

The sub-positions are at the centres of a 4x4 grid inside the pixel. Thus
the sub-positions are at odd multiples of half a sub-pixel. The code
multiplies each coordinate by `2 * samples`, and then the sub-positions are
whole numbers. Thus the distance test is the same comparison of squared
integers as before:

```zig
const scale = samples * 2;
const px = x * scale + 2 * sx + 1;
```

The `+ 1` is the offset of half a sub-pixel. Without the `+ 1`, the samples
are at the corners. Then the full edge moves by half a sub-pixel, which is
one eighth of a pixel here. This error is small and always in the same
direction. When two antialiased shapes must touch, you can see the error.

## The cost

The code does sixteen inside tests for each pixel. The bounding box must also
become one pixel larger on each side, or the code skips pixels that are
partially covered. Because of this cost, supersampling is often the first
technique that people use, and the technique that they replace later.

There are other techniques:

- For a circle, the distance from the centre already tells you how far into
  the edge a pixel is. A ramp one pixel wide on that distance gives a good
  edge with one test.
- Signed distance fields use the same idea for shapes of all types.
- A font rasterizer calculates the coverage of polygon edges analytically.
  Text with samples at this quality would be much too slow.

Supersampling has one advantage that these techniques do not have: it needs
no knowledge of the shape. You can antialias any inside test, whatever its
code. Do the test more times for each pixel. Thus supersampling is a good
first choice, and it can stay the answer for offline rendering.

## Where the result is wrong

On this page, blending occurs in sRGB, as in all other chapters of this
section. Thus a half-covered pixel is darker than half the light of a covered
pixel. For this reason, thin antialiased strokes look thinner than they are.
This problem is very important for text rasterizers. Refer to the note at the
end of [Alpha Blending](../blending/).

## Exercises

1. **Change the sample count.** Use 2x2 samples, and the ramp gets four
   levels instead of sixteen. In the character dump, it is easy to count the
   bands.
2. **Rotate the sample grid.** A regular grid gives the worst result on edges
   that are almost horizontal or almost vertical. For this reason, hardware
   uses rotated grid patterns. Move the samples, and compare the top of the
   circle.
3. **Antialias a line.** Xiaolin Wu's algorithm is Bresenham's algorithm, with
   the error term used again as coverage. It is the idea of this page applied
   to [Lines](../lines/), with no extra samples.
