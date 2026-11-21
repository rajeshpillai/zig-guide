# Convolution

> Blur, sharpen and Sobel are one loop with different numbers in it. The two bugs are always the border and the buffer.

A point operation reads one pixel. A convolution reads a neighbourhood. The
steps are:

1. Move a small matrix over the image.
2. Multiply each weight by the pixel under it.
3. Add the products.
4. Divide the sum.

Blur, sharpen, emboss and edge detection all use this loop. Only the numbers
in the matrix are different.

```zig
const std = @import("std");
const canvas = @import("_canvas.zig");

const count = canvas.width * canvas.height;

var pixels: [count]u32 = undefined;
var scratch: [count]u32 = undefined;

/// A square kernel with an odd side length. The divisor is the sum of its
/// weights.
///
/// `Kernel(3)` and `Kernel(5)` are different types from a type function.
/// Thus the side length is a compile-time constant inside `convolve`, and the
/// inner loops unroll against a known bound.
fn Kernel(comptime side: usize) type {
    comptime std.debug.assert(side % 2 == 1);
    return struct {
        weights: [side * side]i32,
        divisor: i32,

        const radius: i32 = @intCast(side / 2);
    };
}

/// Sample a pixel. Clamp coordinates outside the image to the edge.
///
/// At the border, part of the kernel is outside the image, and the code must
/// do something there. If the code returns black, each blurred image gets a
/// dark frame. If the code wraps to the far side, the top mixes into the
/// bottom. A clamp repeats the edge pixel. You cannot see the clamp, and most
/// image libraries use it by default.
fn sample(src: []const u32, x: i32, y: i32) u32 {
    const cx = std.math.clamp(x, 0, @as(i32, @intCast(canvas.width)) - 1);
    const cy = std.math.clamp(y, 0, @as(i32, @intCast(canvas.height)) - 1);
    return src[@as(usize, @intCast(cy)) * canvas.width + @as(usize, @intCast(cx))];
}

/// The loop. `dst` and `src` must not be the same buffer. A convolution reads
/// neighbours. If the loop writes an output pixel over its input, it corrupts
/// the input of each pixel that comes after it. The bug causes a smear in one
/// direction, not a crash. Thus the bug can stay hidden in hand-written code.
fn convolve(comptime side: usize, dst: []u32, src: []const u32, k: Kernel(side)) void {
    const K = Kernel(side);
    for (0..canvas.height) |y| {
        for (0..canvas.width) |x| {
            var r: i32 = 0;
            var g: i32 = 0;
            var b: i32 = 0;
            for (0..side) |ky| {
                for (0..side) |kx| {
                    const w = k.weights[ky * side + kx];
                    if (w == 0) continue;
                    const c = canvas.channels(sample(
                        src,
                        @as(i32, @intCast(x)) + @as(i32, @intCast(kx)) - K.radius,
                        @as(i32, @intCast(y)) + @as(i32, @intCast(ky)) - K.radius,
                    ));
                    r += w * c.r;
                    g += w * c.g;
                    b += w * c.b;
                }
            }
            dst[y * canvas.width + x] = canvas.rgb(
                clamp8(@divTrunc(r, k.divisor)),
                clamp8(@divTrunc(g, k.divisor)),
                clamp8(@divTrunc(b, k.divisor)),
            );
        }
    }
}

fn clamp8(v: i32) u8 {
    return @intCast(std.math.clamp(v, 0, 255));
}

/// The sum of the weights is 16. Thus the divisor is 16, and the image keeps
/// its brightness. If the sum of the weights is not equal to the divisor, the
/// kernel makes the full image darker or brighter. Usually that is a mistake.
const gaussian3 = Kernel(3){
    .weights = .{
        1, 2, 1,
        2, 4, 2,
        1, 2, 1,
    },
    .divisor = 16,
};

/// The sum of the weights is 1. The kernel increases the centre and subtracts
/// the neighbours. Thus flat areas do not change, and edges become stronger.
const sharpen3 = Kernel(3){
    .weights = .{
        0,  -1, 0,
        -1, 5,  -1,
        0,  -1, 0,
    },
    .divisor = 1,
};

/// The two halves of Sobel. The sum of each half is zero. Thus a flat area
/// gives zero. These kernels measure change, not brightness. The output is a
/// gradient, not an image.
const sobel_x = [9]i32{
    -1, 0, 1,
    -2, 0, 2,
    -1, 0, 1,
};
const sobel_y = [9]i32{
    -1, -2, -1,
    0,  0,  0,
    1,  2,  1,
};

/// Edge strength: run both kernels on luma, and add the two results.
///
/// The exact magnitude is `sqrt(gx*gx + gy*gy)`. On diagonals, `|gx| + |gy|`
/// is up to 41% too large, but it needs no square root. The original hardware
/// implementations used this approximation, and most implementations still do.
fn sobel(dst: []u32, src: []const u32) void {
    for (0..canvas.height) |y| {
        for (0..canvas.width) |x| {
            var gx: i32 = 0;
            var gy: i32 = 0;
            for (0..3) |ky| {
                for (0..3) |kx| {
                    const l: i32 = @intCast(canvas.luma(sample(
                        src,
                        @as(i32, @intCast(x + kx)) - 1,
                        @as(i32, @intCast(y + ky)) - 1,
                    )));
                    gx += sobel_x[ky * 3 + kx] * l;
                    gy += sobel_y[ky * 3 + kx] * l;
                }
            }
            // `@abs` on a signed integer returns the unsigned type of the same
            // width. Thus the code changes the sum to `i32` before the divide.
            const sum: i32 = @intCast(@abs(gx) + @abs(gy));
            const mag = clamp8(@divTrunc(sum, 2));
            dst[y * canvas.width + x] = canvas.rgb(mag, mag, mag);
        }
    }
}

pub fn main(init: std.process.Init) !void {
    var buf: [16384]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    canvas.scene(&pixels);

    // Three blur passes. Three passes of a 3x3 gaussian are approximately
    // equal to a wider gaussian. Three fast passes cost less than one 7x7.
    for (0..3) |_| {
        convolve(3, &scratch, &pixels, gaussian3);
        @memcpy(&pixels, &scratch);
    }
    try out.writeAll("gaussian 3x3, three passes:\n");
    try canvas.dump(out, &pixels);

    canvas.scene(&pixels);
    sobel(&scratch, &pixels);
    try out.writeAll("\nsobel magnitude:\n");
    try canvas.dump(out, &scratch);

    // The answers of the two kernels at three points. Each edge of the block
    // has a gradient in one direction. The flat interior has no gradient.
    try out.writeAll("\n           point |    gx    gy  |gx|+|gy|\n");
    const probes = [_]struct { name: []const u8, x: usize, y: usize }{
        .{ .name = "block interior", .x = 16, .y = 10 },
        .{ .name = "block left edge", .x = 8, .y = 10 },
        .{ .name = "block top edge", .x = 16, .y = 6 },
    };
    for (probes) |p| {
        var gx: i32 = 0;
        var gy: i32 = 0;
        for (0..3) |ky| {
            for (0..3) |kx| {
                const l: i32 = @intCast(canvas.luma(sample(
                    &pixels,
                    @as(i32, @intCast(p.x + kx)) - 1,
                    @as(i32, @intCast(p.y + ky)) - 1,
                )));
                gx += sobel_x[ky * 3 + kx] * l;
                gy += sobel_y[ky * 3 + kx] * l;
            }
        }
        // The sign of `gx` is the direction of the change. The sign is
        // positive where the image becomes brighter to the right. When the
        // format has a width, Zig prints the sign. Here the sign is useful.
        try out.print("{s:>16} | {d:>5} {d:>5} {d:>9}\n", .{ p.name, gx, gy, @abs(gx) + @abs(gy) });
    }

    // Sharpen across the left edge of the block. A sharpen kernel does not
    // add detail. It makes the difference that it finds larger. On a hard
    // edge, the dark side becomes darker and the bright side becomes brighter
    // than before. This overshoot has the name ringing. Each sharpen slider
    // must balance more sharpness against more ringing.
    canvas.scene(&pixels);
    convolve(3, &scratch, &pixels, sharpen3);
    try out.writeAll("\nluma along y=10, x=5..12\n     x |");
    for (5..13) |x| try out.print(" {d:>4}", .{x});
    try out.writeAll("\n  orig |");
    for (5..13) |x| try out.print(" {d:>4}", .{canvas.luma(pixels[10 * canvas.width + x])});
    try out.writeAll("\n sharp |");
    for (5..13) |x| try out.print(" {d:>4}", .{canvas.luma(scratch[10 * canvas.width + x])});
    try out.writeByte('\n');

    // The in-place bug, in a form that you can see. Both versions start from
    // the same picture. One version writes into its own input. (9,7) is the
    // top-left corner of the block. There, the blurred row above it gets into
    // the answer.
    const probe = 7 * canvas.width + 9;

    canvas.scene(&pixels);
    convolve(3, &scratch, &pixels, gaussian3);
    const c = canvas.channels(scratch[probe]);

    canvas.scene(&pixels);
    convolve(3, &pixels, &pixels, gaussian3); // same buffer for src and dst
    const w = canvas.channels(pixels[probe]);

    try out.print("\npixel (9,7) into a second buffer: {d} {d} {d}\n", .{ c.r, c.g, c.b });
    try out.print("pixel (9,7) in place:             {d} {d} {d}\n", .{ w.r, w.g, w.b });

    // A separable kernel as two 1D passes. A 3x3 kernel costs 9 multiplies
    // for each pixel. A horizontal pass and then a vertical pass cost 6. The
    // difference increases with the square of the kernel side.
    //
    // The results are not exactly equal, because of the rounding of the extra
    // divide. The sample is in the gradient, where the rounding can lose a
    // fraction. Inside the saturated block, both versions round to the same
    // byte, and you cannot see the difference.
    const ramp_probe = 20 * canvas.width + 40;

    canvas.scene(&pixels);
    convolve(3, &scratch, &pixels, gaussian3);
    const t = canvas.channels(scratch[ramp_probe]);

    canvas.scene(&pixels);
    convolve(3, &scratch, &pixels, .{ .weights = .{ 0, 0, 0, 1, 2, 1, 0, 0, 0 }, .divisor = 4 });
    convolve(3, &pixels, &scratch, .{ .weights = .{ 0, 1, 0, 0, 2, 0, 0, 1, 0 }, .divisor = 4 });
    const s = canvas.channels(pixels[ramp_probe]);

    try out.print("\npixel (40,20) 3x3 in one pass: {d} {d} {d}\n", .{ t.r, t.g, t.b });
    try out.print("pixel (40,20) as two 1D passes: {d} {d} {d}\n", .{ s.r, s.g, s.b });

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`09-graphics.convolution`)*

## The kernel is a type, not a struct field

```zig
fn Kernel(comptime side: usize) type {
    comptime std.debug.assert(side % 2 == 1);
    return struct {
        weights: [side * side]i32,
        divisor: i32,

        const radius: i32 = @intCast(side / 2);
    };
}
```

`Kernel(3)` and `Kernel(5)` are different types. Inside the convolution loop,
the side length is a compile-time constant. Thus the compiler knows the
bounds, and the inner loops unroll. Also, you cannot give a 5x5 kernel to code
that expects a 3x3 kernel.

A runtime `side: usize` field also compiles, but it loses both of these
advantages. [Comptime](https://www.ziglang.in/learn/language-basics/comptime/) explains type
functions in general. Here the advantage is easy to see.

The `comptime std.debug.assert` runs at compile time. An even side length is
a compile error, not a runtime panic. The reason is that a kernel with no
centre pixel has no meaningful answer.

## The divisor is necessary

The sum of the gaussian weights is 16, and the divisor is 16. Thus the image
keeps its initial brightness.

If the sum of the weights is not equal to the divisor, the kernel changes the
brightness of the full image. Sometimes you want this result. Usually it is a
bug, and you see the bug three filters later.

Two useful special cases:

- The **sharpen** weights have a sum of 1, with a divisor of 1. Flat areas do
  not change, because the neighbours cancel the increase at the centre. Edges
  become stronger than before.
- The **Sobel** weights have a sum of zero. A flat area gives exactly zero.
  Thus the output is not an image. The output is a measurement of change.

## Bug one: the border

At the edge of the image, part of the kernel is outside the image. The code
must do something there. There are three choices, and you can see the result
of each choice:

- Return black for coordinates outside the image. Then each blurred image
  gets a dark frame, and the frame becomes thicker with each pass.
- Wrap to the far side. Then the top row mixes into the bottom row.
- Clamp the coordinate to the edge. Then the edge pixel repeats. You cannot
  see this result, and most image libraries use this choice by default.

```zig
fn sample(src: []const u32, x: i32, y: i32) u32 {
    const cx = std.math.clamp(x, 0, @as(i32, @intCast(canvas.width)) - 1);
    const cy = std.math.clamp(y, 0, @as(i32, @intCast(canvas.height)) - 1);
    return src[@as(usize, @intCast(cy)) * canvas.width + @as(usize, @intCast(cx))];
}
```

The code uses signed coordinates, for the same reason as in
[circles](https://www.ziglang.in/learn/graphics/circles/). Because of the kernel offset, half of
the possible coordinates are negative before the clamp.

## Bug two: the buffer

A convolution must not write into the buffer that it reads.

```zig
convolve(3, &output, &input, gaussian3);  // correct
convolve(3, &input, &input, gaussian3);   // wrong
```

If the code writes an output pixel over its input, it corrupts the input of
each pixel that comes after it. Then the result depends on the order of the
loop.

The snippet does the convolution in both ways at the top-left corner of the
block. It prints the two answers: `255 220 60` and `231 199 58`. Nothing
crashes. The image only shows a small smear in the direction of the scan.
Thus a code review often does not find this bug.

Image pipelines use one of two solutions:

- Keep two buffers, and swap them.
- Write to a new buffer for each pass.

The three-pass blur in the snippet uses a second buffer for each pass.

## A sharpen kernel causes ringing

The output prints the luma across the left edge of the block, before and after
a sharpen:

```
     x |    5    6    7    8    9   10   11   12
  orig |   24   24   25  212  212  212  212  212
 sharp |   25   23    6  233  212  212  212  212
```

The dark side of the edge became darker than before (25 to 6). The bright
side became brighter (212 to 233). A sharpen kernel adds no detail. It makes
the difference that it finds larger.

On a hard edge, this overshoot has the name ringing. A sharpen slider
balances sharpness against ringing. If you move the slider far enough, a halo
always appears.

## Repeat a small kernel

Three passes of a 3x3 gaussian are approximately equal to one 7x7 pass. The
three passes need 27 multiplies for each pixel, and the 7x7 pass needs 49.

Repeated box blurs converge on a true gaussian. The reason is the same reason
that repeated sums of any values converge on a normal distribution. Most fast
blurs use this method.

Separability saves more. The gaussian above factors into a horizontal
`[1 2 1]` and a vertical `[1 2 1]`. Thus 9 multiplies for each pixel become 6.
For a 9x9 kernel, the numbers are 81 and 18. The difference increases with
the square of the side.

The snippet runs both versions and prints the results: `42 42 94` for the
single pass, and `42 42 93` for the two 1D passes. The results are not
exactly equal. The difference is the rounding of the extra division, because
two passes round to a byte two times.

## Sobel, and what the sign means

There are two kernels. One kernel measures change from left to right. The
other kernel measures change from top to bottom:

```
gx = -1  0  1      gy = -1 -2 -1
     -2  0  2            0  0  0
     -1  0  1            1  2  1
```

The snippet tests three points and prints both values:

```
           point |    gx    gy  |gx|+|gy|
  block interior |    +0    +0         0
 block left edge |  +749    +1       750
  block top edge |    +1  +751       752
```

- The interior is flat, and it has no gradient.
- The left edge has a large horizontal gradient and no vertical gradient.
- The top edge has a large vertical gradient and no horizontal gradient.

The sign is the direction. A positive gradient means that the image becomes
brighter to the right. If an edge detector discards the sign, it cannot tell
a light-to-dark edge from a dark-to-light edge.

The correct magnitude is `sqrt(gx*gx + gy*gy)`. On diagonals, `|gx| + |gy|`
is up to 41% too large, but it needs no square root. The original hardware
implementations used this approximation, and most edge detectors still use
it. The next step is almost always a threshold, and the threshold hides the
error.
