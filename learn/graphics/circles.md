# Circles

> Compare squared distances, loop over the bounding box, and let putPixel clip.

A point is inside a circle when its distance to the centre is at most the
radius:

```
sqrt(dx*dx + dy*dy) <= r
```

Square both sides and the square root disappears:

```
dx*dx + dy*dy <= r*r
```

Both sides are now integers, and the test is two multiplies and a compare.
This trick is worth internalizing well beyond graphics: any time you are about
to call `sqrt` in order to *compare* two lengths, don't. Hit testing, nearest
neighbour searches, and collision detection all run on squared distances.

```zig
const std = @import("std");
const canvas = @import("_canvas.zig");

var pixels: [canvas.width * canvas.height]u32 = undefined;

/// Scans every pixel in the buffer, which is the obvious version and the wrong
/// one: at r = 7 it tests 2048 pixels to fill about 150.
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

/// The same circle, looping only over its bounding box. `putPixel` already
/// clips, so a circle hanging off an edge needs no extra handling here.
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

/// An outline is the same test twice: inside the outer radius and outside the
/// inner one. No new algorithm, just a band.
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

    // Hangs off three edges at once. Nothing here checks for that; the clip in
    // putPixel does.
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

The naive version scans the whole buffer to fill one circle. At 64x32 that is
2048 tests for a shape covering about 150 pixels; at 640x480 a circle of
radius 100 costs 307,200 tests to fill 31,000 pixels. Looping `y` and `x` over
`[centre - r, centre + r]` instead tests `(2r+1)^2` pixels, which the snippet
prints alongside the naive count.

The reason this stays a three-line change is that `putPixel` clips. The
bounding box of a circle near an edge runs off the buffer, and nothing in
`fillCircle` checks for that. The last circle in the snippet hangs off three
sides at once to show it. Without clipping in one place, every shape routine
would need its own `@min`/`@max` against the buffer size, and one of them
would eventually get it wrong.

## An outline is the same test twice

```zig
if (d2 <= outer and d2 > inner) putPixel(...);
```

Inside the outer radius and outside the inner one is a band. No new algorithm,
no separate case, and the thickness is a parameter. The midpoint circle
algorithm draws a one-pixel outline faster by walking only one octant and
mirroring it eight ways, which is the circle equivalent of Bresenham. It is
worth reading once. It is also worth knowing that for anything you intend to
fill, the squared-distance test is simpler and vectorizes.

## What is missing

The edge is hard: a pixel is in or out, with nothing between. That is the
staircase you can see in the output. Fixing it means computing what fraction
of each pixel falls inside the circle, and using that as an alpha value.
[Antialiasing](../antialiasing/) does exactly that, on this same shape.

## Exercises

1. **Ellipses.** Scale one axis before squaring: `(dx*dx) * ry*ry + (dy*dy) *
   rx*rx <= rx*rx * ry*ry`. Still integers, still no square root.
2. **Rounded rectangles.** A rectangle, plus the circle test applied only in the
   four corner boxes.
3. **A span fill.** For each row, solve for the two x values where the circle
   crosses it and write that run of pixels directly. One `@memset` per row beats
   a per-pixel test by a wide margin, and it is the shape a real rasterizer uses.
