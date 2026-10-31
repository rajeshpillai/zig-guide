# Colour Matrices

> Grayscale, sepia and saturation are one 3x3 matrix. A chain of these matrices multiplies into one matrix before the program changes the image.

Grayscale, sepia, saturation, hue rotation and channel swaps look like
different filters. They are one filter with different constants: a 3x3 matrix
that multiplies the channel vector.

```
[ R' ]   [ a b c ] [ R ]
[ G' ] = [ d e f ] [ G ]
[ B' ]   [ g h i ] [ B ]
```

When the filters have this form, you can multiply them together. A chain of
four colour filters becomes one matrix. The program calculates that matrix
before it changes the image, and then it makes one pass over the image.

```zig
const std = @import("std");
const canvas = @import("_canvas.zig");

var pixels: [canvas.width * canvas.height]u32 = undefined;
var scratch: [canvas.width * canvas.height]u32 = undefined;

/// Row-major, and each entry uses a scale of 256. The matrix uses fixed point
/// and not floats, because the input and the output are bytes. With `f32`, the
/// program needs a conversion at each end. The `f32` values add precision, but
/// the last `@intCast` removes that precision.
const Matrix = [9]i32;

const scale = 256;

const identity: Matrix = .{
    scale, 0,     0,
    0,     scale, 0,
    0,     0,     scale,
};

/// Rec. 601 luma in all three rows. Each output channel becomes the same
/// weighted average, and the result is grayscale. `canvas.luma` uses the same
/// weights, and the weights sum to exactly 256.
const luma_matrix: Matrix = .{
    77, 150, 29,
    77, 150, 29,
    77, 150, 29,
};

/// The classic sepia matrix. The rows sum to 346, 308 and 241, not 256. This is
/// not a mistake. Sepia must make the image brighter and also tint the image.
/// The red row gets the largest increase, and this is intentional.
const sepia: Matrix = .{
    101, 197, 48,
    89,  176, 43,
    70,  137, 34,
};

/// Saturation is a straight line between grayscale and the original. The line
/// continues past the two ends.
///
///     out = luma + s * (in - luma)
///
/// At `s = 0`, the result is the luma matrix. At `s = 256`, the result is the
/// identity. Above 256, the result moves away from grey, as a saturation slider
/// does past 100%. Saturation is a matrix and not a special case. Thus it
/// composes with the other matrices in this file.
fn saturation(s: i32) Matrix {
    var m: Matrix = undefined;
    for (&m, identity, luma_matrix) |*out, i, l| {
        out.* = @divTrunc(s * i + (scale - s) * l, scale);
    }
    return m;
}

/// The matrix product, in the same fixed point. `compose(a, b)` applies `b`
/// first.
fn compose(a: Matrix, b: Matrix) Matrix {
    var m: Matrix = undefined;
    for (0..3) |row| {
        for (0..3) |col| {
            var sum: i32 = 0;
            for (0..3) |k| sum += a[row * 3 + k] * b[k * 3 + col];
            m[row * 3 + col] = @divTrunc(sum, scale);
        }
    }
    return m;
}

fn transform(color: u32, m: Matrix) u32 {
    const c = canvas.channels(color);
    const r: i32 = c.r;
    const g: i32 = c.g;
    const b: i32 = c.b;
    return canvas.rgb(
        clamp8(@divTrunc(m[0] * r + m[1] * g + m[2] * b, scale)),
        clamp8(@divTrunc(m[3] * r + m[4] * g + m[5] * b, scale)),
        clamp8(@divTrunc(m[6] * r + m[7] * g + m[8] * b, scale)),
    );
}

fn clamp8(v: i32) u8 {
    return @intCast(std.math.clamp(v, 0, 255));
}

fn apply(buf: []u32, m: Matrix) void {
    for (buf) |*p| p.* = transform(p.*, m);
}

pub fn main(init: std.process.Init) !void {
    var buf: [16384]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    canvas.scene(&pixels);
    apply(&pixels, sepia);
    try out.writeAll("sepia:\n");
    try canvas.dump(out, &pixels);

    const samples = [_]struct { name: []const u8, color: u32 }{
        .{ .name = "red disc", .color = canvas.rgb(230, 40, 40) },
        .{ .name = "green disc", .color = canvas.rgb(40, 220, 90) },
        .{ .name = "yellow block", .color = canvas.rgb(255, 220, 60) },
    };
    const shown = [_]struct { name: []const u8, m: Matrix }{
        .{ .name = "identity", .m = identity },
        .{ .name = "sat 0", .m = saturation(0) },
        .{ .name = "sat 200%", .m = saturation(512) },
        .{ .name = "sepia", .m = sepia },
    };

    try out.writeAll("\n");
    for (samples) |s| {
        try out.print("{s:>13}:", .{s.name});
        for (shown) |t| {
            const c = canvas.channels(transform(s.color, t.m));
            try out.print("  {s} {d:>3},{d:>3},{d:>3}", .{ t.name, c.r, c.g, c.b });
        }
        try out.writeByte('\n');
    }

    // Saturation changes chroma and does not change luma. The reason is that
    // the weights that make the grey are the same weights that measure the
    // brightness. Thus the dump of a saturated image is almost the same as the
    // dump of the original. That result is correct. It is not a bug in the dump.
    try out.writeAll("\nluma under saturation (original, sat 0, sat 200%)\n");
    for (samples) |s| {
        try out.print("{s:>13}: {d:>3} {d:>3} {d:>3}\n", .{
            s.name,
            canvas.luma(s.color),
            canvas.luma(transform(s.color, saturation(0))),
            canvas.luma(transform(s.color, saturation(512))),
        });
    }

    // Composition and its cost. Two passes round to a byte two times. The
    // composed matrix rounds one time, in the matrix product. The results are
    // close, but they are not identical. A lookup table is different: a
    // composition of point operations on 8-bit channels is exact. A composition
    // of matrices is not exact.
    canvas.scene(&pixels);
    apply(&pixels, saturation(160));
    apply(&pixels, sepia);

    canvas.scene(&scratch);
    apply(&scratch, compose(sepia, saturation(160)));

    var worst: i32 = 0;
    var differing: usize = 0;
    for (pixels, scratch) |a, b| {
        const ca = canvas.channels(a);
        const cb = canvas.channels(b);
        const d = @max(
            @abs(@as(i32, ca.r) - @as(i32, cb.r)),
            @max(@abs(@as(i32, ca.g) - @as(i32, cb.g)), @abs(@as(i32, ca.b) - @as(i32, cb.b))),
        );
        if (d > 0) differing += 1;
        worst = @max(worst, @as(i32, @intCast(d)));
    }
    try out.print(
        "\ntwo passes vs one composed matrix: {d} of {d} pixels differ, by at most {d}\n",
        .{ differing, pixels.len, worst },
    );

    const composed = compose(sepia, saturation(160));
    try out.writeAll("\nsepia . saturation(62%) =\n");
    for (0..3) |row| {
        try out.print("  {d:>4} {d:>4} {d:>4}\n", .{
            composed[row * 3], composed[row * 3 + 1], composed[row * 3 + 2],
        });
    }

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`09-graphics.color-matrix`)*

## Write grayscale as a matrix

Put the luma weights in all three rows:

```zig
const luma_matrix: Matrix = .{
    77, 150, 29,
    77, 150, 29,
    77, 150, 29,
};
```

Each output channel becomes the same weighted average, and the result is
grayscale.

The entries use a scale of 256, and the multiply divides by 256 at the end.
Thus all of the arithmetic stays in integers. Floats add precision, but the
last cast to `u8` removes that precision. Floats also need a conversion at
each end.

## Saturation is a line through grey

```
out = luma + s * (in - luma)
```

The value of `s` controls the result:

- At `s = 0`, the result is grayscale.
- At `s = 1`, the result is the original.
- Above 1, the result continues in the same direction, away from grey.

As a matrix, saturation is a blend of the luma matrix and the identity:

```zig
fn saturation(s: i32) Matrix {
    var m: Matrix = undefined;
    for (&m, identity, luma_matrix) |*out, i, l| {
        out.* = @divTrunc(s * i + (scale - s) * l, scale);
    }
    return m;
}
```

Saturation is a matrix and not a special case. Thus it composes with the other
matrices.

The output shows that saturation changes chroma and does not change
brightness:

```
luma under saturation (original, sat 0, sat 200%)
     red disc:  97  97  76
   green disc: 151 151 152
 yellow block: 212 212 209
```

Grayscale keeps the luma exactly, because the definition of the grey that it
makes is the luma. At 200%, the numbers change, and the red disc falls from 97
to 76.

The cause is clipping. The maths is correct. When the saturation of red goes past
100%, the channels go past 0 or 255, and the program clamps them. A clipped
colour does not have the luma that the matrix asked for. Thus each saturation
control, at a sufficiently high value, decreases the brightness of the colours
that it makes stronger.

## The rows of sepia do not sum to 256

```zig
const sepia: Matrix = .{
    101, 197, 48,
    89,  176, 43,
    70,  137, 34,
};
```

The rows sum to 346, 308 and 241. A row with a sum of 256 keeps the
brightness. The sepia rows do not, and this is intentional.

Sepia must make the image brighter while it tints the image. The red row gets
the largest increase, and that increase gives the warm colour. If you
"correct" the rows to a sum of 256, you get a dull grey-brown. That colour does
not look like sepia.

Thus, know which type of matrix you have. If a matrix sums to more than 256 by
mistake, it makes the highlights too bright for no reason.

## Composition and its cost

The product of two colour matrices is the matrix that applies the two
matrices:

```zig
fn compose(a: Matrix, b: Matrix) Matrix { ... }  // applies b first
```

Sepia after 62% saturation, as one matrix:

```
  +100 +198  +43
   +89 +177  +38
   +70 +138  +30
```

The program makes one pass over the image, not two. The saving increases with
the length of the chain. A photo app with six adjustments does one matrix
multiply per pixel, not six.

The composition is not exact:

```
two passes vs one composed matrix: 1560 of 2048 pixels differ, by at most 1
```

Two passes round to a byte between the two steps. The composed matrix rounds
one time, inside the matrix product.

The lookup tables in [per-pixel transforms](https://www.ziglang.in/learn/graphics/per-pixel/) were
different: a composition of tables was exact to the last bit. A table maps
bytes to bytes, so a composition adds no error. A matrix holds fractions. If
you round the fractions earlier or later, you get different answers.

A difference of one per channel is too small to see, and the two-pass version
is the more accurate of the two. Composition truncates the nine matrix entries.
Then the program multiplies each of those errors by a channel value, which can
be as large as 255. Two roundings during the passes lose less than one rounding
of the matrix.

This fact is important for tests. The same filter with a different order of
operations does not give output that is identical bit for bit. A test that
compares images byte for byte fails on this difference.

## What a matrix cannot do

**Spatial operations.** A colour matrix reads one pixel. Blur, sharpen and
edge detection need neighbours. Those operations are
[convolution](https://www.ziglang.in/learn/graphics/convolution/), a different loop with a different
cost.

**Non-linear operations.** Gamma, curves and thresholds are not linear
functions of the channels, so no matrix can express them. Those operations are
lookup tables. A full pipeline uses the two: tables for the curves, and a
matrix for the colour mix.

**Alpha.** The matrices on this page are 3x3 over RGB. Systems that include
alpha use a 4x5 matrix: four rows, and four coefficients plus a constant
offset in each row. The CSS `feColorMatrix` filter and the Android
`ColorMatrix` both use this form. The extra column lets a matrix add a
constant, and a tint toward a fixed colour needs that constant.

All of the operations on this page also multiply sRGB bytes directly. The
warning from [alpha blending](https://www.ziglang.in/learn/graphics/blending/) applies here too:
sRGB bytes are not linear light. A colour operation that must be accurate
converts to linear light first.
