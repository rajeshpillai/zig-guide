# Histograms and Levels

> Count what the image contains, and get the correction table from the counts. Auto-levels, equalization, and why to apply them to luma.

The tables in [per-pixel transforms](https://www.ziglang.in/learn/graphics/per-pixel/) were
constants: you selected a contrast factor and made a table from it. The tables
on this page come from a measurement. Count the number of pixels at each luma
value. The correction that the image needs comes directly from the counts.

```zig
fn histogram(src: []const u32) [256]u32 {
    var hist: [256]u32 = @splat(0);
    for (src) |p| hist[canvas.luma(p)] += 1;
    return hist;
}
```

The function uses 256 counters and one pass. The analysis needs nothing more.
All of the other results on this page come from these counts.

```zig
const std = @import("std");
const canvas = @import("_canvas.zig");

var pixels: [canvas.width * canvas.height]u32 = undefined;

const Lut = [256]u8;

/// The number of pixels at each luma value. 256 counters and one pass.
fn histogram(src: []const u32) [256]u32 {
    var hist: [256]u32 = @splat(0);
    for (src) |p| hist[canvas.luma(p)] += 1;
    return hist;
}

/// Sixteen buckets, because 256 rows of text are too many to read. 16 rows
/// show the shape.
fn printHistogram(out: *std.Io.Writer, hist: [256]u32, label: []const u8) !void {
    var buckets: [16]u32 = @splat(0);
    for (hist, 0..) |n, value| buckets[value / 16] += n;

    var peak: u32 = 1;
    for (buckets) |n| peak = @max(peak, n);

    try out.print("{s}\n", .{label});
    for (buckets, 0..) |n, i| {
        // The program scales the bars to the tallest bucket. Thus you can read the
        // shape for all values of the absolute counts.
        const bar = (n * 40) / peak;
        try out.print("{d:>3}..{d:>3} |", .{ i * 16, i * 16 + 15 });
        for (0..bar) |_| try out.writeByte('#');
        try out.print(" {d}\n", .{n});
    }
}

/// The luma value where the count reaches `per_mille` of the pixels (in
/// 1/1000ths). The program uses it to find where the image really starts and
/// stops. It does not assume 0 and 255.
fn percentile(hist: [256]u32, total: u32, per_mille: u32) u8 {
    const target = (total * per_mille) / 1000;
    var seen: u32 = 0;
    for (hist, 0..) |n, value| {
        seen += n;
        if (seen >= target) return @intCast(value);
    }
    return 255;
}

/// Levels: map `black` to 0 and `white` to 255 linearly, and clip the values
/// outside that range. The shape is the same as the contrast table from the
/// per-pixel chapter. The difference is that the program measures the two
/// endpoints. It does not get them as a choice.
fn levelsLut(black: u8, white: u8) Lut {
    var lut: Lut = undefined;
    const span: i32 = @max(1, @as(i32, white) - @as(i32, black));
    for (&lut, 0..) |*v, i| {
        const shifted = @as(i32, @intCast(i)) - @as(i32, black);
        v.* = @intCast(std.math.clamp(@divTrunc(shifted * 255, span), 0, 255));
    }
    return lut;
}

/// Equalization: the table is the cumulative distribution, rescaled.
///
/// Where many pixels share a value, the CDF increases quickly. Thus that range
/// spreads over more output values. Where the image has no pixels, the CDF is
/// flat, and that range becomes almost nothing. The result uses the full range,
/// with approximately the same number of pixels at each level. That is the
/// maximum contrast that the data supports, and it is frequently too much.
fn equalizeLut(hist: [256]u32, total: u32) Lut {
    var lut: Lut = undefined;
    var cdf: u32 = 0;
    var cdf_min: u32 = 0;
    var found_min = false;

    for (hist, 0..) |n, i| {
        cdf += n;
        if (!found_min and cdf > 0) {
            cdf_min = cdf;
            found_min = true;
        }
        // The subtraction of cdf_min puts the darkest level that has pixels at
        // 0. Without it, a picture with no true black never gets to black.
        const numerator = (cdf - cdf_min) * 255;
        const denominator = @max(1, total - cdf_min);
        lut[i] = @intCast(std.math.clamp(numerator / denominator, 0, 255));
    }
    return lut;
}

/// The usual method: apply the table to each channel independently.
fn applyPerChannel(buf: []u32, lut: Lut) void {
    for (buf) |*p| {
        const c = canvas.channels(p.*);
        p.* = canvas.rgb(lut[c.r], lut[c.g], lut[c.b]);
    }
}

/// The other method: get the new brightness from luma, then scale the three
/// channels by the same ratio. The hue does not change, because the ratios
/// between the channels hold the hue.
fn applyLuma(buf: []u32, lut: Lut) void {
    for (buf) |*p| {
        const before = canvas.luma(p.*);
        if (before == 0) continue;
        const after = lut[before];
        const c = canvas.channels(p.*);
        p.* = canvas.rgb(
            scaleChannel(c.r, after, before),
            scaleChannel(c.g, after, before),
            scaleChannel(c.b, after, before),
        );
    }
}

fn scaleChannel(value: u8, numerator: u32, denominator: u32) u8 {
    const scaled = (@as(u32, value) * numerator) / denominator;
    return @intCast(@min(scaled, 255));
}

pub fn main(init: std.process.Init) !void {
    var buf: [32768]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    canvas.scene(&pixels);
    const total: u32 = @intCast(pixels.len);
    const hist = histogram(&pixels);
    try printHistogram(out, hist, "original");

    // Find the range that the picture really uses. If the program reads the
    // extremes from the ends of the histogram, one stray pixel can set the full
    // range. To prevent this, auto-levels implementations clip a fraction first.
    const black = percentile(hist, total, 10); // 1%
    const white = percentile(hist, total, 990); // 99%
    try out.print("\n1st percentile: {d}   99th percentile: {d}\n", .{ black, white });

    const levels = levelsLut(black, white);
    const equalize = equalizeLut(hist, total);

    try out.writeAll("\n  in | levels equalize\n");
    for ([_]u8{ 0, 32, 64, 96, 128, 160, 192, 224, 255 }) |v| {
        try out.print(" {d:>3} | {d:>6} {d:>8}\n", .{ v, levels[v], equalize[v] });
    }

    canvas.scene(&pixels);
    applyLuma(&pixels, equalize);
    try out.writeAll("\nequalized:\n");
    try canvas.dump(out, &pixels);
    try out.writeByte('\n');
    try printHistogram(out, histogram(&pixels), "after equalization");

    // Compare the per-channel method with the luma method on a pixel with a
    // strong colour. The program uses the levels table, which is gentler than
    // the equalization table. The per-channel method changes each channel
    // independently. Thus the ratios between the channels change, and the hue
    // changes too. In the per-channel result, the red channel clips at 255.
    canvas.scene(&pixels);
    const red_before = pixels[10 * canvas.width + 44];

    var a = [_]u32{red_before};
    applyPerChannel(&a, levels);
    var b = [_]u32{red_before};
    applyLuma(&b, levels);

    const cb = canvas.channels(red_before);
    const cp = canvas.channels(a[0]);
    const cl = canvas.channels(b[0]);
    try out.print("\nred disc before:    {d:>3},{d:>3},{d:>3}  R/B = {d}.{d:0>2}\n", .{
        cb.r, cb.g, cb.b, cb.r / cb.b, (@as(u32, cb.r) * 100 / cb.b) % 100,
    });
    try out.print("levels per channel: {d:>3},{d:>3},{d:>3}  R/B = {d}.{d:0>2}\n", .{
        cp.r, cp.g, cp.b, cp.r / cp.b, (@as(u32, cp.r) * 100 / cp.b) % 100,
    });
    try out.print("levels on luma:     {d:>3},{d:>3},{d:>3}  R/B = {d}.{d:0>2}\n", .{
        cl.r, cl.g, cl.b, cl.r / cl.b, (@as(u32, cl.r) * 100 / cl.b) % 100,
    });

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`09-graphics.histogram`)*

## Read the shape

Most of the histogram of the test picture is in the low third:

- The background ramp is between 13 and 68.
- The block and the discs are three separate spikes at higher values.
- No pixel has a value from 80 to 95 or from 112 to 143.

The picture uses approximately half of the range that it has.

This shape is the numeric meaning of "the image looks flat". Levels and
equalization each correct this shape in a different way.

## Levels: measure the ends

The simple correction stretches the range of the image to fill 0 to 255. The
only question is where the image really starts and stops. The answer is not
the first and the last bin that is not empty:

```zig
const black = percentile(hist, total, 10);   // 1%
const white = percentile(hist, total, 990);  // 99%
```

The program clips a fraction at each end first, and this is intentional.
Without the clip, one hot pixel at 255 or one dead pixel at 0 sets the full
range. Then the stretch does nothing. All auto-levels implementations clip,
and the fraction is the only setting.

The result is the contrast table from
[per-pixel transforms](https://www.ziglang.in/learn/graphics/per-pixel/). The difference is that the
endpoints come from a measurement, and the user does not select them.

## Equalization: the table is the distribution

Equalization does more. It does not use a linear stretch. It makes the output
histogram as flat as possible, so each output level has approximately the
same number of pixels. The table for this operation is the cumulative
distribution:

```zig
lut[i] = (cdf[i] - cdf_min) * 255 / (total - cdf_min);
```

Where many pixels share a range, the CDF increases quickly. Thus that range
spreads over many output values. Where the image has no pixels, the CDF is
flat, and that range becomes almost nothing.

The subtraction of `cdf_min` puts the darkest level that has pixels at 0.
Without the subtraction, a picture with no true black never gets to black.

The change in the output is large. The background ramp had three shades that
were almost the same. After equalization, the ramp is a wide gradient with
visible structure.

## What equalization cannot do

Look at the equalized histogram in the output. It is flatter, but it still has
empty buckets. One bucket holds 300 pixels, and another bucket holds 77.

Equalization moves values to different positions, but it cannot make new
values. If 153 pixels share one luma value, the 153 pixels still share one
luma value after equalization. The CDF moves that spike to a new position, and
the gaps on each side of the spike stay. A fully flat histogram is possible
only when the input has as many different values as the output has levels.

Equalization also makes the sparse regions stronger, and the noise in those
regions too. A flat sky with sensor grain becomes a flat sky with visible
sensor grain. The algorithm cannot see the difference between detail to
stretch and noise to keep as it is.

For this reason, photo tools supply equalization, but photographers rarely use
it without changes. The usual solution is CLAHE. CLAHE equalizes small tiles
independently, and it limits how far each level can stretch.

## Apply it to brightness, not to channels

There are two ways to apply a table to a colour image, and the two ways give
different results:

```zig
// Per channel: run the table over R, G and B independently.
p.* = canvas.rgb(lut[c.r], lut[c.g], lut[c.b]);

// On luma: decide the new brightness, then scale all three by the same ratio.
p.* = scaleAll(c, lut[luma], luma);
```

The output measures the difference on the red disc:

```
red disc before:    230, 40, 40  R/B = 5.75
levels per channel: 255, 32, 32  R/B = 7.96
levels on luma:     251, 43, 43  R/B = 5.83
```

The ratios between the channels hold the hue. A curve is not linear. Thus,
when each channel goes through the same curve independently, the ratios
change. The colour becomes more saturated, and the hue moves.

The other method gets the new brightness from luma. Then it multiplies the
three channels by that one factor. The ratios stay the same, and only the
brightness changes.

The per-channel method is not always wrong. The "auto colour" operation uses
it intentionally. Levels on each channel separately also remove a colour cast.
For example, if the blue channel is never more than 200, a stretch to 255
corrects a yellow tint.

- If the colour cast is the problem, use the per-channel method.
- If the colours are part of the picture, use luma.
