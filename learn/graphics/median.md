# Median and Rank Filters

> A convolution cannot ignore a value. Sort the neighbourhood, and one function is a denoiser, an eroder or a dilator. The index decides which.

A [convolution](https://www.ziglang.in/learn/graphics/convolution/) is a weighted sum. Each pixel
under the kernel adds something to the result. No weight has the meaning
"this value is wrong, ignore it". A family of filters, the rank filters, does
not have this limit.

Sort the neighbourhood, and then select a pixel by its position.

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

/// Salt and pepper: black or white fully replaces a fraction of the pixels. A
/// bad sensor or a lossy channel makes this noise. The two filters in this file
/// give very different results on it, because the corrupted values are not
/// similar to their neighbours.
///
/// The program uses a fixed multiplier and a fixed seed. Thus the picture is the same on each
/// run, and the repository can store the expected output.
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

/// A 3x3 gaussian, for comparison. Each neighbour adds something to the
/// result. Thus the gaussian does not remove one white pixel. It spreads the
/// pixel over nine pixels.
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
/// One function for the full family. Rank 4 is the median, rank 0 is the
/// minimum and rank 8 is the maximum. `rank` is `comptime`, so each
/// instantiation is a separate specialised function. A hot loop has no branch
/// for the rank.
///
/// The function sorts full pixels, not separate channels. A median of each
/// channel separately can make a colour that is not in the neighbourhood.
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
            // Insertion sort. For nine elements, the O(n^2) bound is not
            // important, and insertion sort has almost no constant overhead.
            // Production code uses a fixed sorting network here. A network is
            // straight-line code with no loop and no branches.
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

/// Count the pixels that are pure black or pure white. After the noise pass,
/// this count is almost equal to the count of the noise that remains.
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

/// The mean absolute difference in luma between two pictures, in 1/100ths.
/// Thus the integer print keeps two decimals.
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

    // Two measurements, because the first measurement gives a wrong idea. The
    // count of pure black and pure white says that the gaussian removed each
    // noisy pixel. That is true: the gaussian averaged each noisy pixel into a
    // grey smudge nine pixels wide. The mean error against the clean picture
    // tells you if the noise is gone or only spread.
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

    // The edge, before and after each filter. The gaussian makes the edge soft,
    // because it averages across the edge. The median does not, because on each
    // side of the edge, most of the window is on that side.
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
    // shrinks the shape by one pixel, and the maximum filter grows the shape.
    // These filters are erosion and dilation, from the same function with a
    // different index.
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

Sort the nine pixels of a 3x3 window by brightness, and take the pixel at
`rank`:

- Rank 4 is the median.
- Rank 0 is the minimum, which is erosion.
- Rank 8 is the maximum, which is dilation.

Basic morphology and the standard denoiser are the same loop with a different
index. The choice is comptime. Thus each rank compiles to its own specialised
function, and the inner loop has no branch for the rank.

The output checks the morphology at the end. The block has 153 pixels that
are brighter than 200. Erosion decreases this number to 105, and dilation
increases it to 209. Thus bright regions shrink or grow by one pixel at the
boundary.

Erosion followed by dilation is opening, and dilation followed by erosion is
closing. These operations remove small specks and do not change the size of
large shapes.

## Why the median is better than the blur on this noise

Salt and pepper noise replaces a pixel fully with black or white. The
corrupted value has no relation to the old value. A weighted average gives a
bad result in this case:

```
            black white  mean luma error vs clean
     noisy:    54    75        9.03
  gaussian:     0     0       11.80
    median:     0     2        1.59
```

If you read only the first two columns, the gaussian looks perfect. Not one
pure black or pure white pixel stays. But those two columns do not measure the
quality of the image.

The gaussian removed each noisy pixel because it averaged the pixel into a
grey smudge nine pixels wide. The third column shows the cost. The mean error
against the clean picture *increased*, from 9.03 to 11.80. After the gaussian,
the image is further from the clean picture than the noisy input was.

The median discards the outlier. In a window of nine values with one extreme
value, the extreme value goes to one end of the sorted window. The middle
element is one of the eight correct values. The error decreases to 1.59.

This rule is general. A small number of outliers moves a mean away from the
true value. A median ignores outliers fully, if the outliers are fewer than
half of the values. For the same reason, statistics uses the median for
income.

## Why the median keeps the edge

```
     x    |    5    6    7    8    9   10   11   12
 original |   24   24   25  212  212  212  212  212
 gaussian |   23   24   71  165  212  212  212  212
   median |   24   24   25  212  212  212  212  212
```

The gaussian makes the edge of the block soft. At a pixel on the boundary, the
window covers the two sides, and the average is a value between them.

The median does not move the edge. At each pixel on the dark side, five or
more of the nine neighbours are dark. Thus the middle element is dark, and the
edge stays exactly at the same position.

Programs use rank filters because rank filters smooth an image and do not move
edges. They cost more than a blur: the program sorts nine values per pixel,
where a blur does nine multiplies and one divide.

## The sort

The window has nine elements, so the program uses insertion sort:

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

The quadratic bound is not important at this size, and insertion sort has
almost no constant overhead.

Production implementations use a fixed compare-exchange network. A network is
straight-line code with no loop and no branches that depend on the data. One
mispredicted branch per pixel is expensive, and a network has no branches. You
can also vectorise a network directly, but you cannot vectorise the loop
above.

The size of the network depends on the result that you need. A full sort of
nine elements takes 25 compare-exchanges, but the median alone takes 19. A
selection network must put only the middle value in its correct position. The
other values in the window can be in any order.

## Sort full pixels, not channels

The window holds packed pixels and sorts them by luma. Thus the output is a
colour from the neighbourhood.

A median of the red channel, the green channel and the blue channel
independently is easier, but it is wrong. The three medians can come from
three different pixels. The result is then a colour that was not in the
window. On coloured noise, this method makes colours that were never in the
image.

## The next filters in the family

The median has a weakness. It gives the same importance to each pixel in the
window. The distance of a pixel and the difference in its colour have no
effect.

The bilateral filter corrects this weakness. It gives a weight to each
neighbour from the distance and from the colour difference. Thus it smooths
flat regions and keeps edges, and it keeps edges better than a median does.
The bilateral filter is a weighted average again. But its weights depend on
the data, so it is not a convolution either.
