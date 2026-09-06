# A Bar Chart

> Turning numbers into pixels is one division, and getting it wrong is a lie.

A chart is the first drawing in this section whose shape is not chosen by the
programmer. The bars are as tall as the data says, which means there is a
function from a number to a pixel height, and that function is where charts go
wrong.

It is one division. Everything interesting is in what you divide by.

## The program

```zig
const std = @import("std");

const width: usize = 48;
const height: usize = 17;
var canvas: [width * height]u8 = @splat(' ');

const plot_left: usize = 5;
// Two rows spare below the plot: one for the axis, one for the labels.
const plot_bottom: usize = height - 3;
const plot_top: usize = 1;

fn put(x: usize, y: usize, ink: u8) void {
    if (x >= width or y >= height) return;
    canvas[y * width + x] = ink;
}

/// Map a value onto pixels. The denominator is the decision: dividing by the
/// largest value makes the tallest bar fill the plot, which is what makes two
/// charts side by side incomparable unless they share a scale.
fn barHeight(value: u32, max: u32, rows: usize) usize {
    if (max == 0) return 0;
    return @intCast(@as(usize, value) * rows / max);
}

fn drawAxes() void {
    var y = plot_top;
    while (y <= plot_bottom) : (y += 1) put(plot_left - 1, y, '|');
    var x = plot_left - 1;
    while (x < width - 1) : (x += 1) put(x, plot_bottom + 1, '-');
    put(plot_left - 1, plot_bottom + 1, '+');
}

fn drawBar(slot: usize, value: u32, max: u32, ink: u8) void {
    const rows = plot_bottom - plot_top + 1;
    const h = barHeight(value, max, rows);
    const x = plot_left + slot * 5;

    var i: usize = 0;
    while (i < h) : (i += 1) {
        const y = plot_bottom - i;
        put(x, y, ink);
        put(x + 1, y, ink);
        put(x + 2, y, ink);
    }
}

fn dump(out: *std.Io.Writer) !void {
    for (0..height) |y| try out.print("{s}\n", .{canvas[y * width ..][0..width]});
}

pub fn main(init: std.process.Init) !void {
    var buf: [4096]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    const labels = [_]u8{ 'a', 'b', 'c', 'd', 'e', 'f', 'g' };
    const values = [_]u32{ 12, 31, 24, 8, 40, 19, 27 };

    var max: u32 = 0;
    for (values) |v| max = @max(max, v);

    drawAxes();
    for (values, 0..) |v, i| {
        drawBar(i, v, max, '#');
        put(plot_left + i * 5 + 1, plot_bottom + 2, labels[i]);
    }
    // The scale, written down. A chart without one is a picture of a shape.
    put(0, plot_top, '4');
    put(1, plot_top, '0');
    put(0, plot_bottom, '0');

    try dump(out);

    try out.print("\nmax is {d}, plot is {d} rows tall\n", .{ max, plot_bottom - plot_top + 1 });
    for (values, 0..) |v, i| {
        try out.print("  {c} = {d: >3}  ->  {d} rows\n", .{
            labels[i],
            v,
            barHeight(v, max, plot_bottom - plot_top + 1),
        });
    }

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`09-graphics.chart`)*

## What just happened

**Each bar is `value * rows / max`.** The largest value fills the plot exactly,
because it is the denominator. That is a choice, not an obligation, and it has
a consequence: two charts drawn this way cannot be compared, because each one
silently used a different scale.

**The integer division truncates, and the table shows it.** 12 of 40 over 14
rows is 4.2, drawn as 4. Every bar is up to one row shorter than it should be,
never taller. That bias is invisible in the picture and is why a chart with a
handful of pixels per bar can misrepresent small differences.

**The axis is drawn, and so is the scale.** `40` at the top and `0` at the
bottom. Without them the picture shows a shape and claims nothing: the reader
cannot tell whether the tallest bar is 40 or 40,000, or whether the baseline
is zero at all.

## The lie a bar chart can tell

Start the vertical axis somewhere other than zero and the bars stop being
proportional to their values. A bar twice as tall as another no longer means
twice as much, and the reader has no way to see it except by reading the axis
labels. Reading labels is exactly what a glance at a chart does not do.

For a **bar** chart this is a genuine error, because the bar's length is the
encoding: the whole point is that area and value are proportional. For a
**line** chart it is often correct, since a line encodes change rather than
magnitude and a truncated axis is how you see a small change at all.

The rule falls out of what the mark means, which is why it is worth writing
the mapping function by hand once.

## Check yourself

The chart divides by the largest value in the data. When is that wrong?

Whenever the reader will compare this chart with another one, which includes
every dashboard, every set of small multiples, and every chart that updates
over time. If the scale changes when the data changes, a bar can grow while
its value shrinks.

The fix is to fix the denominator: a scale chosen for the domain rather than
the data, shared by every chart drawn against it. That is the same reasoning
as a shared axis on a set of small multiples, and it is the most common thing
missing from charts assembled by code.

## If you have written C

The drawing is trivial and the arithmetic is where the care goes. The
multiplication overflows if the product exceeds the type, which for a `u32`
count and a large plot is closer than it looks. So it wants a wider type, or a
different order of operations.

The other C-specific hazard is the empty case. `max` is 0 when every value is
0, and the division is then by zero: in C undefined behaviour, in a safety
build here a caught panic. The function above returns 0 for that case
explicitly, because a chart of nothing is a legitimate chart and crashing on
it is not.
