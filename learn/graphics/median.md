# Median and Rank Filters

> A convolution cannot ignore a value. Sorting the neighbourhood gives one function that is a denoiser, an eroder and a dilator depending on the index.

A [convolution](https://www.ziglang.in/learn/graphics/convolution/) is a weighted sum. Every pixel
under the kernel contributes something, and there is no weight that means
"this value is wrong, disregard it". That limitation has a name and a whole
family of filters that get around it.

Sort the neighbourhood and pick by position instead.

```zig
const std = @import("std");
const canvas = @import("_canvas.zig");

const count = canvas.width * canvas.height;

var pixels: [count]u32 = undefined;
var scratch: [count]u32 = undefined;

fn sample(src: []const u32, x: i32, y: i32) u32 {
    const cx = std.math.clamp(x, 0, @as(i32, @intCast(canvas.width)) - 1);
    const cy = std.math.clamp(y, 0, @as(i32, @intCast(canvas.height)) - 1);
    return src[@as(usize, @intCast(cy)) * canvas.width + @as(usize, @intCast(cx))];
}

/// Salt and pepper: a fraction of pixels replaced outright by black or white.
/// This is the noise a bad sensor or a lossy channel produces, and it is the
/// case that separates the two filters here, because the corrupted values are
/// nothing like their neighbours.
///
/// A fixed multiplier and seed, so the picture is the same on every run and the
/// expected output can be checked in.
fn addSaltAndPepper(buf: []u32, per_mille: u32) void {
    var state: u64 = 0x2545F4914F6CDD1D;
    for (buf) |*p| {
        state = state *% 6364136223846793005 +% 1442695040888963407;
        const roll: u32 = @intCast((state >> 33) % 1000);
        if (roll < per_mille) {
            p.* = if (roll % 2 == 0) canvas.rgb(0, 0, 0) else canvas.rgb(255, 255, 255);
        }
    }
}

/// A 3x3 gaussian, for comparison. Every neighbour contributes something, which
/// is exactly the problem: a single white pixel is not removed, it is spread
/// over nine.
fn blur(dst: []u32, src: []const u32) void {
    const weights = [9]i32{ 1, 2, 1, 2, 4, 2, 1, 2, 1 };
    for (0..canvas.height) |y| {
        for (0..canvas.width) |x| {
            var r: i32 = 0;
            var g: i32 = 0;
            var b: i32 = 0;
            for (0..3) |ky| {
                for (0..3) |kx| {
                    const w = weights[ky * 3 + kx];
                    const c = canvas.channels(sample(
                        src,
                        @as(i32, @intCast(x + kx)) - 1,
                        @as(i32, @intCast(y + ky)) - 1,
                    ));
                    r += w * c.r;
                    g += w * c.g;
                    b += w * c.b;
                }
            }
            dst[y * canvas.width + x] = canvas.rgb(
                @intCast(@divTrunc(r, 16)),
                @intCast(@divTrunc(g, 16)),
                @intCast(@divTrunc(b, 16)),
            );
        }
    }
}

/// Sort the nine neighbours by luma and take the one at `rank`.
///
/// The whole family in one function. Rank 4 is the median, rank 0 the minimum
/// and rank 8 the maximum, and `rank` being `comptime` means each instantiation
/// is a separate specialised function rather than a branch in a hot loop.
///
/// The pixel is carried through whole rather than sorted per channel: taking
/// the median of each channel separately can produce a colour that appears
/// nowhere in the neighbourhood.
fn rankFilter(dst: []u32, src: []const u32, comptime rank: usize) void {
    comptime std.debug.assert(rank < 9);
    for (0..canvas.height) |y| {
        for (0..canvas.width) |x| {
            var window: [9]u32 = undefined;
            for (0..3) |ky| {
                for (0..3) |kx| {
                    window[ky * 3 + kx] = sample(
                        src,
                        @as(i32, @intCast(x + kx)) - 1,
                        @as(i32, @intCast(y + ky)) - 1,
                    );
                }
            }
            // Insertion sort. Nine elements is small enough that the O(n^2)
            // bound is beaten in practice by having no branches to mispredict
            // and no call overhead; production code uses a fixed sorting
            // network here, which is straight-line code with no loop at all.
            var i: usize = 1;
            while (i < window.len) : (i += 1) {
                const key = window[i];
                var j = i;
                while (j > 0 and canvas.luma(window[j - 1]) > canvas.luma(key)) : (j -= 1) {
                    window[j] = window[j - 1];
                }
                window[j] = key;
            }
            dst[y * canvas.width + x] = window[rank];
        }
    }
}

/// Count pixels that are pure black or pure white, which after the noise pass
/// is very nearly a count of the surviving noise.
fn countExtremes(buf: []const u32) struct { black: usize, white: usize } {
    var black: usize = 0;
    var white: usize = 0;
    for (buf) |p| {
        const l = canvas.luma(p);
        if (l == 0) black += 1;
        if (l >= 254) white += 1;
    }
    return .{ .black = black, .white = white };
}

/// Mean absolute luma difference between two pictures, in 1/100ths so the
/// integer print keeps two decimals.
fn meanError(a: []const u32, b: []const u32) u32 {
    var total: u64 = 0;
    for (a, b) |pa, pb| {
        const la: i32 = @intCast(canvas.luma(pa));
        const lb: i32 = @intCast(canvas.luma(pb));
        total += @abs(la - lb);
    }
    return @intCast((total * 100) / a.len);
}

fn printRow(out: *std.Io.Writer, label: []const u8, black: usize, white: usize, err: u32) !void {
    try out.print("{s:>10}: {d:>5} {d:>5} {d:>8}.{d:0>2}\n", .{ label, black, white, err / 100, err % 100 });
}

fn lumaRow(out: *std.Io.Writer, label: []const u8, buf: []const u32) !void {
    try out.print("{s:>9} |", .{label});
    for (5..13) |x| try out.print(" {d:>4}", .{canvas.luma(buf[10 * canvas.width + x])});
    try out.writeByte('\n');
}

pub fn main(init: std.process.Init) !void {
    var buf: [32768]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    canvas.scene(&pixels);
    addSaltAndPepper(&pixels, 60); // 6% of pixels
    try out.writeAll("6% salt and pepper:\n");
    try canvas.dump(out, &pixels);

    rankFilter(&scratch, &pixels, 4);
    try out.writeAll("\nmedian 3x3:\n");
    try canvas.dump(out, &scratch);

    const noisy = countExtremes(&pixels);
    const medianed = countExtremes(&scratch);
    blur(&scratch, &pixels);
    const blurred = countExtremes(&scratch);

    // Two measurements, because the first one lies. Counting pure black and
    // pure white says the gaussian removed every noisy pixel, and it did: it
    // averaged each one into a grey smudge nine pixels wide. Mean error against
    // the clean picture is the measurement that says whether the noise is gone
    // or merely spread out.
    var clean: [count]u32 = undefined;
    canvas.scene(&clean);

    rankFilter(&scratch, &pixels, 4);
    const median_error = meanError(&scratch, &clean);
    blur(&scratch, &pixels);
    const blur_error = meanError(&scratch, &clean);

    try out.print("\n            black white  mean luma error vs clean\n", .{});
    try printRow(out, "noisy", noisy.black, noisy.white, meanError(&pixels, &clean));
    try printRow(out, "gaussian", blurred.black, blurred.white, blur_error);
    try printRow(out, "median", medianed.black, medianed.white, median_error);

    // The edge, before and after each filter. The gaussian softens it because
    // it averages across it; the median does not, because on either side of the
    // edge the majority of the window is still on that side.
    canvas.scene(&pixels);
    try out.writeAll("\nluma along y=10, x=5..12 (the block's left edge)\n     x    |");
    for (5..13) |x| try out.print(" {d:>4}", .{x});
    try out.writeByte('\n');
    try lumaRow(out, "original", &pixels);
    blur(&scratch, &pixels);
    try lumaRow(out, "gaussian", &scratch);
    rankFilter(&scratch, &pixels, 4);
    try lumaRow(out, "median", &scratch);

    // Rank 0 and rank 8 are morphology. On a bright shape, the minimum filter
    // shrinks it by a pixel and the maximum grows it: erosion and dilation,
    // from the same function with a different index.
    canvas.scene(&pixels);
    var bright_before: usize = 0;
    for (pixels) |p| {
        if (canvas.luma(p) > 200) bright_before += 1;
    }

    rankFilter(&scratch, &pixels, 0);
    var eroded: usize = 0;
    for (scratch) |p| {
        if (canvas.luma(p) > 200) eroded += 1;
    }

    rankFilter(&scratch, &pixels, 8);
    var dilated: usize = 0;
    for (scratch) |p| {
        if (canvas.luma(p) > 200) dilated += 1;
    }

    try out.print("\npixels brighter than 200: {d} before, {d} after erosion, {d} after dilation\n", .{
        bright_before, eroded, dilated,
    });

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`09-graphics.median`)*

## One function, three filters

```zig
fn rankFilter(dst: []u32, src: []const u32, comptime rank: usize) void
```

Sort the nine pixels of a 3x3 window by brightness and take the one at `rank`.
Rank 4 is the median. Rank 0 is the minimum, which is erosion. Rank 8 is the
maximum, which is dilation. The whole of basic morphology and the standard
denoiser are the same loop with a different index. And because the choice is
comptime, each one compiles to its own specialised function rather than a
branch in the inner loop.

The output confirms the morphology at the end: the block and discs cover 153
pixels brighter than 200, which erosion cuts to 105 and dilation grows to 209.
Bright regions shrink and grow by a pixel of boundary. Running one then the
other is opening and closing, which is how small specks get removed without
changing the size of anything large.

## Why the median beats the blur on this noise

Salt and pepper noise replaces a pixel outright with black or white. The
corrupted value has no relationship to what was there, which is precisely the
case a weighted average handles badly:

```
            black white  mean luma error vs clean
     noisy:    54    75        9.03
  gaussian:     0     0       11.80
    median:     0     2        1.59
```

Read the first two columns alone and the gaussian looks perfect: not a single
pure black or pure white pixel survives. It is a useless measurement. The
gaussian removed each noisy pixel by averaging it into a grey smudge nine
pixels wide. The third column says what that cost: mean error against the
clean picture went *up*, from 9.03 to 11.80. The filter made the image worse
than the noise did.

The median throws the outlier away. In a window of nine where one value is
extreme, the extreme value sorts to an end and the middle element is one of
the eight that were fine. Error drops to 1.59.

This is the general principle. A mean is dragged by any outlier no matter how
few; a median ignores up to half of them entirely. It is the same reason
statistics reports medians for income.

## And why it keeps the edge

```
     x    |    5    6    7    8    9   10   11   12
 original |   24   24   25  212  212  212  212  212
 gaussian |   23   24   71  165  212  212  212  212
   median |   24   24   25  212  212  212  212  212
```

The gaussian softens the block's edge, because at a pixel on the boundary the
window straddles both sides and the average lands in between. The median does
not move it at all. At any pixel on the dark side, at least five of the nine
neighbours are still dark, so the middle element is dark. The edge stays
exactly where it was.

Edge-preserving smoothing is the property that makes rank filters worth their
cost, and the cost is real: nine values sorted per pixel against nine
multiplies and one divide.

## The sort

Nine elements, so insertion sort:

```zig
var i: usize = 1;
while (i < window.len) : (i += 1) {
    const key = window[i];
    var j = i;
    while (j > 0 and canvas.luma(window[j - 1]) > canvas.luma(key)) : (j -= 1) {
        window[j] = window[j - 1];
    }
    window[j] = key;
}
```

The quadratic bound does not matter at this size, and insertion sort has
almost no constant overhead. Production implementations go further and use a
fixed sorting network: 19 compare-and-swap operations for nine elements, in
straight-line code with no loop and no data-dependent branches at all. That
matters because a mispredicted branch per pixel is expensive, and a sorting
network has none. It is also directly vectorisable, which the loop above is
not.

If you only need the median rather than the full order, you can stop early:
selection needs fewer comparisons than a sort. The 19-operation network is
already close enough to the floor that most code does not bother.

## Sort whole pixels, not channels

The window holds packed pixels and sorts them by luma, so the output is a
colour that genuinely appeared in the neighbourhood. Taking the median of the
red channel, the green channel and the blue channel independently is easier,
and it is wrong. The three medians can come from three different pixels,
producing a colour that was nowhere in the window. On coloured noise that
invents colours that were never in the image.

## Where the family goes next

The median's weakness is that it treats every pixel in the window as equally
relevant regardless of how far away it is or how different it is. The
bilateral filter fixes that by weighting each neighbour by both distance and
colour difference, which smooths flat regions while leaving edges alone even
better than a median does. It is a weighted average again, but with weights
that depend on the data, so it is not a convolution either.
