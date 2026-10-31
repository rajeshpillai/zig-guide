# A Bar Chart

> One division changes numbers into pixels. If the division is wrong, the chart misleads the reader.

In this section, a chart is the first drawing where the programmer does not select the shape. The data sets the height of each bar. Thus a function changes a number into a height in pixels, and charts go wrong in that function.

The function is one division. The difficult part is to select the value to divide by.

## The program

```zig
const std = @import("std");

const width: usize = 48;
const height: usize = 17;
var canvas: [width * height]u8 = @splat(' ');

const plot_left: usize = 5;
// Keep two rows below the plot: one row for the axis, one row for the labels.
const plot_bottom: usize = height - 3;
const plot_top: usize = 1;

fn put(x: usize, y: usize, ink: u8) void {
    if (x >= width or y >= height) return;
    canvas[y * width + x] = ink;
}

/// Map a value to pixels. The denominator sets the scale. When the function
/// divides by the largest value, the tallest bar fills the plot. Thus you can
/// compare two charts only if the two charts use the same scale.
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
    // Write the scale on the chart. Without the scale, the reader cannot tell
    // what the heights of the bars mean.
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

**Each bar is `value * rows / max`.** The largest value is the denominator, thus the largest bar fills the plot exactly. This scale is not the only possible scale, and the choice has a result. You cannot compare two charts that use this scale, because each chart used a different scale and did not tell you.

**The integer division truncates, and the table shows the truncation.** 12 of 40 over 14 rows is 4.2, and the program draws 4. Each bar is up to one row shorter than the correct height, and never taller. You cannot see this bias in the picture. If a chart has only a small number of pixels for each bar, the bias can show small differences incorrectly.

**The program draws the axis, and also the scale.** `40` is at the top and `0` is at the bottom. Without these labels, the picture shows a shape and makes no claim. The reader cannot tell if the tallest bar is 40 or 40,000. The reader also cannot tell if the baseline is zero.

## The lie that a bar chart can tell

If the vertical axis starts at a value other than zero, the bars are not proportional to their values. A bar that is two times as tall as another bar does not mean two times the value. The reader can see this problem only in the axis labels. A quick look at a chart does not read the labels.

For a **bar** chart, a vertical axis that does not start at zero is an error. The length of the bar is the encoding, thus the area and the value must be proportional. For a **line** chart, the same axis is frequently correct. A line shows change, not magnitude. A truncated axis lets you see a small change.

The rule comes from the meaning of the mark. When you write the mapping function yourself one time, the rule becomes clear.

## Check yourself

The chart divides by the largest value in the data. When is that division wrong?

The division is wrong when the reader compares this chart with a different chart. Examples are all dashboards, all sets of small multiples, and all charts that update over time. If the scale changes when the data changes, a bar can grow while its value becomes smaller.

To fix the problem, use a fixed denominator. Select a scale for the domain, not for the data, and use that scale for all of the charts. A shared axis on a set of small multiples uses the same logic. Charts that code makes frequently do not have this shared scale.

## If you know C

The drawing is easy. The arithmetic needs the care. The multiplication overflows if the product is too large for the type. With a `u32` count and a large plot, usual data can cause this overflow. Thus the multiplication needs a wider type, or a different order of operations.

The other hazard in C is the empty case. When each value is 0, `max` is 0, and the division is a division by zero. In C, the result is undefined behaviour. In a safety build of Zig, the result is a panic that the runtime catches. The function above returns 0 for that case explicitly. A chart where all values are zero is a valid chart, and the chart must draw without a crash.
