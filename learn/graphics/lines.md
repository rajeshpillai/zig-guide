# Lines

> Bresenham's algorithm: one add and one compare per pixel, integers only.

A line between two pixels is a question about rounding. The ideal line passes
between pixel centres almost everywhere, and the algorithm has to decide, at
each step, which side to land on.

The obvious answer is to compute `y = y0 + slope * (x - x0)` and round it.
That works, costs a float multiply and a rounding per pixel, and drifts on
long lines because the error accumulates. Bresenham's algorithm asks the same
question with an integer error term that is updated by addition, and it never
drifts because nothing is ever rounded.

```zig
const std = @import("std");
const canvas = @import("_canvas.zig");

var pixels: [canvas.width * canvas.height]u32 = undefined;

/// The error term `err` tracks twice the distance from the ideal line to the
/// pixel centre, scaled so it stays an integer. Each step it decides whether
/// the minor axis has drifted far enough to advance too.
///
/// Written in the symmetric form: `dy` is kept negative so both axes are
/// handled by the same two ifs, with no separate case for steep lines and no
/// swapping of endpoints.
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
        // Two independent tests, not an if/else: on a perfect diagonal both
        // fire and the line steps in both axes at once.
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

    // A fan out to evenly spaced points along the border. Every slope from
    // near-horizontal to near-vertical goes through the same code path.
    var i: i32 = 0;
    while (i < 16) : (i += 1) {
        const t = @divTrunc(i * (w - 1), 16);
        _ = drawLine(cx, cy, t, 0, canvas.rgb(255, 200, 60));
        _ = drawLine(cx, cy, w - 1 - t, h - 1, canvas.rgb(120, 200, 255));
    }

    // A border, drawn as four lines, to show the endpoints land exactly.
    _ = drawLine(0, 0, w - 1, 0, canvas.rgb(255, 255, 255));
    _ = drawLine(w - 1, 0, w - 1, h - 1, canvas.rgb(255, 255, 255));
    _ = drawLine(w - 1, h - 1, 0, h - 1, canvas.rgb(255, 255, 255));
    _ = drawLine(0, h - 1, 0, 0, canvas.rgb(255, 255, 255));

    try canvas.dump(out, &pixels);

    // A line lights up max(|dx|, |dy|) + 1 pixels: exactly one per step of the
    // major axis, whatever the slope.
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

## What the error term is

`err` tracks how far the ideal line has drifted from the pixel just plotted,
scaled so it stays a whole number. Each step, the major axis always advances
and the minor axis advances only when the accumulated error says it has fallen
a full pixel behind. Comparing `2 * err` against `dx` and `dy` is where the
scale factor of two comes from: it lets the comparison happen against a
half-pixel threshold without ever dividing.

The form in the snippet keeps `dy` negative:

```zig
const dx: i32 = @intCast(@abs(x1 - x0));
const dy: i32 = -@as(i32, @intCast(@abs(y1 - y0)));
```

That is what collapses the eight cases (four quadrants, shallow and steep)
into one loop. Textbook presentations often swap the endpoints, or swap `x`
and `y` for steep lines, and then need two nearly identical loops. This
version needs neither.

The two tests are deliberately not an `if`/`else`:

```zig
if (e2 >= dy) { err += dy; x += sx; }
if (e2 <= dx) { err += dx; y += sy; }
```

On an exact diagonal both fire, and the line steps in both axes at once. Turn
the second into an `else` and diagonals grow a stair-step.

## The pixel count is the point

A line lights up `max(|dx|, |dy|) + 1` pixels: exactly one per step of the
major axis, whatever the slope. The snippet prints this for three slopes. It
is a useful invariant to check when you write your own version. The two ways
to get it wrong, an off-by-one at the end or a doubled step on diagonals, both
show up in that number before they show up in the picture.

This is not free. It holds because the error term is symmetric, and it is
worth verifying, because a renderer that draws shared edges from both
directions will otherwise leave seams.

## What this version does not do

**No thickness.** Every line here is one pixel wide. A thick line is a
rectangle, or a polygon with round joins, and neither is a small change.

**No antialiasing.** Every pixel is fully on or fully off, which is why the
diagonals in the output have visible steps. Xiaolin Wu's line algorithm is
Bresenham with the error term reused as a coverage value, and it is the same
idea [Antialiasing](../antialiasing/) applies to a circle.

**No clipping beyond `putPixel`.** A line from far off one edge to far off
another still walks every pixel in between and throws away most of them. That
is fine at this size and wasteful at any real one; the Cohen-Sutherland
algorithm trims the endpoints to the buffer before the loop starts.
