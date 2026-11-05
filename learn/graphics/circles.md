# Circles

> Compare squared distances, loop over the bounding box, and let putPixel clip.

A point is inside a circle when the distance from the point to the centre is not more than the radius:

```
sqrt(dx*dx + dy*dy) <= r
```

Square the two sides, and the square root goes away:

```
dx*dx + dy*dy <= r*r
```

Now the two sides are integers, and the test is two multiplies and a compare. This method is useful in many areas, not only in graphics. If you must *compare* two lengths, do not call `sqrt`. Hit testing, nearest neighbour searches and collision detection all use squared distances.

```zig
const std = @import("std");
const canvas = @import("_canvas.zig");

var pixels: [canvas.width * canvas.height]u32 = undefined;

/// Scans each pixel in the buffer. This is the simple version, and it does
/// too much work: at r = 7 it tests 2048 pixels to fill about 150.
fn fillCircleNaive(cx: i32, cy: i32, r: i32, color: u32) usize {
    var tested: usize = 0;
    for (0..canvas.height) |y| {
        for (0..canvas.width) |x| {
            tested += 1;
            const dx = @as(i32, @intCast(x)) - cx;
            const dy = @as(i32, @intCast(y)) - cy;
            if (dx * dx + dy * dy <= r * r) {
                canvas.putPixel(&pixels, @intCast(x), @intCast(y), color);
            }
        }
    }
    return tested;
}

/// The same circle, with a loop over only its bounding box. `putPixel`
/// clips, thus a circle that goes past an edge needs no extra code here.
fn fillCircle(cx: i32, cy: i32, r: i32, color: u32) usize {
    var tested: usize = 0;
    var y = cy - r;
    while (y <= cy + r) : (y += 1) {
        var x = cx - r;
        while (x <= cx + r) : (x += 1) {
            tested += 1;
            const dx = x - cx;
            const dy = y - cy;
            if (dx * dx + dy * dy <= r * r) {
                canvas.putPixel(&pixels, x, y, color);
            }
        }
    }
    return tested;
}

/// An outline is the same test two times: inside the outer radius and outside
/// the inner radius. The algorithm is the same, and the result is a band.
fn strokeCircle(cx: i32, cy: i32, r: i32, thickness: i32, color: u32) void {
    const outer = r * r;
    const inner = (r - thickness) * (r - thickness);
    var y = cy - r;
    while (y <= cy + r) : (y += 1) {
        var x = cx - r;
        while (x <= cx + r) : (x += 1) {
            const dx = x - cx;
            const dy = y - cy;
            const d2 = dx * dx + dy * dy;
            if (d2 <= outer and d2 > inner) {
                canvas.putPixel(&pixels, x, y, color);
            }
        }
    }
}

pub fn main(init: std.process.Init) !void {
    var buf: [8192]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    canvas.fill(&pixels, canvas.rgb(0, 0, 40));

    strokeCircle(20, 16, 13, 2, canvas.rgb(120, 200, 255));
    const naive = fillCircleNaive(20, 16, 7, canvas.rgb(255, 220, 40));
    const boxed = fillCircle(45, 16, 10, canvas.rgb(180, 255, 140));

    // This circle goes past two edges at the same time: the right edge and the
    // bottom edge. No code here checks for that. The clip in putPixel does.
    _ = fillCircle(62, 30, 8, canvas.rgb(255, 120, 120));

    try canvas.dump(out, &pixels);

    try out.print("\nfull-buffer scan, r=7:  {d} pixels tested\n", .{naive});
    try out.print("bounding box,     r=10: {d} pixels tested\n", .{boxed});
    try out.print("a circle of r=10 covers about {d} pixels\n", .{
        (314 * 10 * 10) / 100,
    });

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`09-graphics.circles`)*

## The bounding box

The simple version scans the full buffer to fill one circle. At 64x32, the scan does 2048 tests for a shape of about 150 pixels. At 640x480, a circle of radius 100 costs 307,200 tests to fill 31,000 pixels.

A better version loops `y` and `x` over `[centre - r, centre + r]`. This version tests `(2r+1)^2` pixels. The snippet prints this count next to the count for the simple version.

The change is only three lines, because `putPixel` clips. When a circle is near an edge, its bounding box goes outside the buffer, and `fillCircle` does not check for this. To show this, the last circle in the snippet goes past two sides of the buffer at the same time.

If the clipping is not in one place, each shape routine needs its own `@min`/`@max` against the buffer size. Then, at some time, one of those routines will be wrong.

## An outline is the same test two times

```zig
if (d2 <= outer and d2 > inner) putPixel(...);
```

The pixels inside the outer radius and outside the inner radius make a band. The band needs no new algorithm and no special case, and the thickness is a parameter.

The midpoint circle algorithm draws a one-pixel outline faster. It calculates only one octant and mirrors the octant eight ways. It is the circle version of Bresenham, and you should read it one time. But if you want to fill a shape, the squared-distance test is simpler, and the compiler can vectorize it.

## What the circles do not have

The edge is hard: a pixel is in or out, with no value between. This is the staircase that you see in the output. To correct the edge, calculate the fraction of each pixel that is inside the circle, and use that fraction as an alpha value. [Antialiasing](../antialiasing/) does exactly this, on the same shape.

## Exercises

1. **Ellipses.** Scale one axis before you square it: `(dx*dx) * ry*ry + (dy*dy) *
   rx*rx <= rx*rx * ry*ry`. The values are still integers, and there is still no square root.
2. **Rounded rectangles.** Draw a rectangle, and apply the circle test only in the four corner boxes.
3. **A span fill.** For each row, find the two x values where the circle crosses the row. Then write that run of pixels directly. One `@memset` for each row is much faster than a test for each pixel, and production rasterizers use this method.
