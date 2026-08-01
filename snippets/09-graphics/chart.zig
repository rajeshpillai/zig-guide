//! title: A Bar Chart
//! Turning numbers into pixels is one division, and getting it wrong is a lie.

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
