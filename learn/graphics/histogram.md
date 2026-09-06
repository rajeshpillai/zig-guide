# Histograms and Levels

> Count what the image contains, and the lookup table that fixes it falls out of the counts. Auto-levels, equalization, and why you apply them to luma.

The tables in [per-pixel transforms](https://www.ziglang.in/learn/graphics/per-pixel/) were
constants: you chose a contrast factor and built a table from it. The tables
here are measured. Count how many pixels sit at each luma value, and the
correction the image needs falls out of the counts.

```zig
fn histogram(src: []const u32) [256]u32 {
    var hist: [256]u32 = @splat(0);
    for (src) |p| hist[canvas.luma(p)] += 1;
    return hist;
}
```

Two hundred and fifty six counters and one pass. That is the whole analysis
step, and everything on this page is derived from it.

```zig
const std = @import("std");
const canvas = @import("_canvas.zig");

var pixels: [canvas.width * canvas.height]u32 = undefined;

const Lut = [256]u8;

/// How many pixels sit at each luma value. 256 counters and one pass.
fn histogram(src: []const u32) [256]u32 {
    var hist: [256]u32 = @splat(0);
    for (src) |p| hist[canvas.luma(p)] += 1;
    return hist;
}

/// Sixteen buckets, because 256 rows of text is a wall and 16 is a shape.
fn printHistogram(out: *std.Io.Writer, hist: [256]u32, label: []const u8) !void {
    var buckets: [16]u32 = @splat(0);
    for (hist, 0..) |n, value| buckets[value / 16] += n;

    var peak: u32 = 1;
    for (buckets) |n| peak = @max(peak, n);

    try out.print("{s}\n", .{label});
    for (buckets, 0..) |n, i| {
        // Bars scaled to the tallest bucket, so the shape is readable whatever
        // the absolute counts are.
        const bar = (n * 40) / peak;
        try out.print("{d:>3}..{d:>3} |", .{ i * 16, i * 16 + 15 });
        for (0..bar) |_| try out.writeByte('#');
        try out.print(" {d}\n", .{n});
    }
}

/// The luma value at which `fraction` of the pixels (in 1/1000ths) have been
/// counted. Used to find where the image really starts and stops, rather than
/// trusting 0 and 255.
fn percentile(hist: [256]u32, total: u32, per_mille: u32) u8 {
    const target = (total * per_mille) / 1000;
    var seen: u32 = 0;
    for (hist, 0..) |n, value| {
        seen += n;
        if (seen >= target) return @intCast(value);
    }
    return 255;
}

/// Levels: map `black` to 0 and `white` to 255, linearly, clipping outside.
/// This is the same shape as the contrast table from the per-pixel chapter,
/// except the two endpoints are measured rather than chosen.
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
/// Where many pixels share a value the CDF climbs steeply, so that range gets
/// spread over more output values. Where the image has nothing, the CDF is flat
/// and the range is compressed away. The result uses the whole range with
/// roughly equal population per level, which is the most contrast the data
/// supports and is often more than anyone wanted.
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
        // Subtracting cdf_min anchors the darkest occupied level at 0. Without
        // it a picture with no true black never reaches black.
        const numerator = (cdf - cdf_min) * 255;
        const denominator = @max(1, total - cdf_min);
        lut[i] = @intCast(std.math.clamp(numerator / denominator, 0, 255));
    }
    return lut;
}

/// The obvious way: run the table over each channel independently.
fn applyPerChannel(buf: []u32, lut: Lut) void {
    for (buf) |*p| {
        const c = canvas.channels(p.*);
        p.* = canvas.rgb(lut[c.r], lut[c.g], lut[c.b]);
    }
}

/// The other way: decide the new brightness from luma, then scale all three
/// channels by the same ratio. Hue survives, because the ratios between the
/// channels are what carry it.
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

    // Where the picture actually lives. Reading the extremes off the ends of
    // the histogram would let a single stray pixel set the whole range, which
    // is why every auto-levels implementation clips a fraction first.
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

    // Per-channel against luma-preserving, on a strongly coloured pixel, using
    // the gentler levels table so nothing clips and the difference is the
    // method rather than the ceiling. The per-channel version pushes each
    // channel independently, so the ratios between them change and so does the
    // hue.
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

## Reading the shape

The histogram of the test picture is bunched into the low third. The
background ramp lives between 16 and 63, and the block and discs are three
isolated spikes higher up. Nothing at all occupies 80 to 95 or 112 to 143. The
picture is using about half the range it has.

That shape is what "the image looks flat" means numerically, and it is what
levels and equalization each fix in a different way.

## Levels: measure the ends

The straightforward correction stretches whatever range the image occupies to
fill 0 to 255. The only question is where the image really starts and stops,
and the answer is not the first and last non-empty bin:

```zig
const black = percentile(hist, total, 10);   // 1%
const white = percentile(hist, total, 990);  // 99%
```

Clipping a fraction at each end first is not an approximation, it is the
point. A single hot pixel at 255, or one dead pixel at 0, would otherwise set
the whole range and the stretch would do nothing. Every auto-levels
implementation clips, and the fraction is the only knob.

The table that results is the contrast table from two chapters ago with
measured endpoints instead of chosen ones.

## Equalization: the table is the distribution

Equalization asks for more. Instead of a linear stretch it makes the output
histogram as flat as it can, so that every output level holds about the same
number of pixels. The table that does this is the cumulative distribution:

```zig
lut[i] = (cdf[i] - cdf_min) * 255 / (total - cdf_min);
```

Where many pixels share a range the CDF climbs steeply, so that range gets
spread over many output values. Where the image has nothing, the CDF is flat
and the range is compressed to almost nothing. The `cdf_min` subtraction
anchors the darkest occupied level at 0, without which a picture containing no
true black never reaches black.

The result in the output is dramatic: the background ramp, which was three
barely distinguishable shades, becomes a broad gradient with visible
structure.

## What equalization cannot do

Look at the equalized histogram in the output. It is flatter, but it still has
empty buckets, and one bucket holds 300 pixels while another holds 77.

Equalization redistributes values; it cannot invent them. If 821 pixels share
a single luma value, they still share a single luma value afterwards. It moves
that spike to wherever the CDF puts it and leaves the gaps on either side. A
perfectly flat histogram is only achievable with as many distinct input values
as output levels.

The other thing worth knowing is that equalization amplifies whatever is in
the sparse regions, including noise. A flat sky with sensor grain becomes a
flat sky with visible sensor grain, because the algorithm cannot tell the
difference between detail worth stretching and noise worth leaving alone. This
is why photo tools offer it and photographers rarely use it as-is. The usual
answer is CLAHE, which equalizes small tiles independently and limits how far
any one level may be stretched.

## Apply it to brightness, not to channels

There are two ways to run a table over a colour image and they are not the
same:

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

Hue is carried by the ratios between the channels. Pushing each channel
through the same curve independently changes those ratios, because a curve is
not linear, so a colour comes out more saturated and shifted. Deciding the new
brightness from luma and scaling all three by that one factor keeps the ratios
and moves only the brightness.

Per-channel is not always wrong. It is what "auto colour" does deliberately.
Running levels on each channel separately also removes a colour cast: if the
blue channel never exceeds 200, stretching it to 255 corrects a yellow tint.
Which one you want depends on whether the cast is the problem or the picture.
