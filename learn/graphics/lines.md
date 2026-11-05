# Lines

> Bresenham's algorithm: one add and one compare per pixel, integers only.

A line between two pixels is a question about rounding. Almost everywhere, the ideal line goes between pixel centres. At each step, the algorithm must decide on which side to put the pixel.

The obvious answer is to calculate `y = y0 + slope * (x - x0)` and round the result. This method works, but it costs a float multiply and a rounding for each pixel. On long lines, the result drifts, because the error accumulates. Bresenham's algorithm asks the same question with an integer error term. The algorithm updates the error term by addition. It does not drift, because it never rounds a value.

```zig
const std = @import("std");
const canvas = @import("_canvas.zig");

var pixels: [canvas.width * canvas.height]u32 = undefined;

/// The error term `err` records twice the distance from the ideal line to the
/// pixel centre, scaled so that it stays an integer. At each step, it decides
/// if the minor axis is far enough behind to advance too.
///
/// This is the symmetric form: `dy` stays negative, thus the same two ifs
/// move the two axes. There is no special case for steep lines, and no swap
/// of the endpoints.
fn drawLine(x0: i32, y0: i32, x1: i32, y1: i32, color: u32) usize {
    var x = x0;
    var y = y0;

    const dx: i32 = @intCast(@abs(x1 - x0));
    const dy: i32 = -@as(i32, @intCast(@abs(y1 - y0)));
    const sx: i32 = if (x0 < x1) 1 else -1;
    const sy: i32 = if (y0 < y1) 1 else -1;

    var err = dx + dy;
    var drawn: usize = 0;

    while (true) {
        canvas.putPixel(&pixels, x, y, color);
        drawn += 1;
        if (x == x1 and y == y1) break;

        const e2 = 2 * err;
        // Two independent tests, not an if/else. On a perfect diagonal, the
        // two tests are both true, and the line moves on the two axes at once.
        if (e2 >= dy) {
            err += dy;
            x += sx;
        }
        if (e2 <= dx) {
            err += dx;
            y += sy;
        }
    }

    return drawn;
}

pub fn main(init: std.process.Init) !void {
    var buf: [8192]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    canvas.fill(&pixels, canvas.rgb(0, 0, 40));

    const cx: i32 = @intCast(canvas.width / 2);
    const cy: i32 = @intCast(canvas.height / 2);
    const w: i32 = @intCast(canvas.width);
    const h: i32 = @intCast(canvas.height);

    // A fan of lines to points at equal distances along the border. All slopes,
    // from almost horizontal to almost vertical, use the same code path.
    var i: i32 = 0;
    while (i < 16) : (i += 1) {
        const t = @divTrunc(i * (w - 1), 16);
        _ = drawLine(cx, cy, t, 0, canvas.rgb(255, 200, 60));
        _ = drawLine(cx, cy, w - 1 - t, h - 1, canvas.rgb(120, 200, 255));
    }

    // A border of four lines, to show that the endpoints are exact.
    _ = drawLine(0, 0, w - 1, 0, canvas.rgb(255, 255, 255));
    _ = drawLine(w - 1, 0, w - 1, h - 1, canvas.rgb(255, 255, 255));
    _ = drawLine(w - 1, h - 1, 0, h - 1, canvas.rgb(255, 255, 255));
    _ = drawLine(0, h - 1, 0, 0, canvas.rgb(255, 255, 255));

    try canvas.dump(out, &pixels);

    // A line sets max(|dx|, |dy|) + 1 pixels: exactly one for each step of the
    // major axis, at all slopes.
    const probe = canvas.rgb(0, 0, 40);
    try out.print("\n(0,0)->(40,10): {d} pixels\n", .{drawLine(0, 0, 40, 10, probe)});
    try out.print("(0,0)->(10,30): {d} pixels\n", .{drawLine(0, 0, 10, 30, probe)});
    try out.print("(0,0)->(20,20): {d} pixels\n", .{drawLine(0, 0, 20, 20, probe)});
    try out.print("(40,10)->(0,0): {d} pixels (same line, drawn backwards)\n", .{
        drawLine(40, 10, 0, 0, probe),
    });

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`09-graphics.lines`)*

## The error term

`err` records how far the ideal line is from the pixel that the loop plotted last. The code scales the value, so that it stays a whole number.

At each step, the major axis always advances. The minor axis advances only when the accumulated error shows that the line is a full pixel behind. The scale factor of two comes from the comparison of `2 * err` with `dx` and `dy`. With this factor, the comparison uses a half-pixel threshold, and the code does not divide.

The form in the snippet keeps `dy` negative:

```zig
const dx: i32 = @intCast(@abs(x1 - x0));
const dy: i32 = -@as(i32, @intCast(@abs(y1 - y0)));
```

When `dy` is negative, the eight cases (four quadrants, shallow and steep) become one loop. Many textbooks swap the endpoints, or swap `x` and `y` for steep lines. Then they need two loops that are almost the same. This version needs neither change.

The two tests are intentionally not an `if`/`else`:

```zig
if (e2 >= dy) { err += dy; x += sx; }
if (e2 <= dx) { err += dx; y += sy; }
```

On an exact diagonal, the two tests are both true, and the line moves on the two axes at the same time. If you change the second test into an `else`, the diagonals get a stair-step.

## The pixel count

A line sets `max(|dx|, |dy|) + 1` pixels: exactly one for each step of the major axis, at all slopes. The snippet prints this count for three slopes.

When you write your own version, check this invariant. There are two possible errors: an off-by-one at the end, or a double step on diagonals. Both errors show in the count before they show in the picture.

The count is correct only because the error term is symmetric. Check that a line drawn backwards gives the same count. If it does not, a renderer that draws shared edges from the two directions leaves seams.

## What this version does not do

**No thickness.** All lines here are one pixel wide. A thick line is a rectangle, or a polygon with round joins. Neither is a small change.

**No antialiasing.** Each pixel is fully on or fully off. Thus the diagonals in the output have visible steps. Xiaolin Wu's line algorithm is Bresenham with the error term used again as a coverage value. [Antialiasing](../antialiasing/) applies the same idea to a circle.

**No clipping other than in `putPixel`.** Think of a line that starts far outside one edge and ends far outside a different edge. The loop still goes through each pixel between the endpoints, and `putPixel` discards most of them. At this size, the cost is small. At larger sizes, the cost is a waste. The Cohen-Sutherland algorithm cuts the endpoints to the buffer before the loop starts.
