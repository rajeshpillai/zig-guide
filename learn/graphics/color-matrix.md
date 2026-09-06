# Colour Matrices

> Grayscale, sepia and saturation are one 3x3 matrix, and a chain of them multiplies into a single matrix before the image is touched.

Grayscale, sepia, saturation, hue rotation and channel swaps look like
separate filters. They are one filter with different constants: a 3x3 matrix
multiplying the channel vector.

```
[ R' ]   [ a b c ] [ R ]
[ G' ] = [ d e f ] [ G ]
[ B' ]   [ g h i ] [ B ]
```

The reason to write them this way is not elegance. It is that matrices
multiply, so a chain of four colour filters becomes one matrix computed before
the image is touched, and then one pass.

```zig
const std = @import("std");
const canvas = @import("_canvas.zig");

var pixels: [canvas.width * canvas.height]u32 = undefined;
var scratch: [canvas.width * canvas.height]u32 = undefined;

/// Row-major, every entry scaled by 256. Fixed point rather than floats
/// because the input and output are bytes: carrying `f32` through would add a
/// conversion at each end to buy precision that the final `@intCast` throws
/// away.
const Matrix = [9]i32;

const scale = 256;

const identity: Matrix = .{
    scale, 0,     0,
    0,     scale, 0,
    0,     0,     scale,
};

/// Rec. 601 luma in all three rows: every output channel becomes the same
/// weighted average, which is grayscale. The weights are the ones
/// `canvas.luma` uses, and they sum to exactly 256.
const luma_matrix: Matrix = .{
    77, 150, 29,
    77, 150, 29,
    77, 150, 29,
};

/// The classic sepia matrix. Its rows sum to 346, 308 and 241 rather than 256,
/// which is not a mistake: sepia is meant to lift the image as well as tint it,
/// and the red row deliberately gains the most.
const sepia: Matrix = .{
    101, 197, 48,
    89,  176, 43,
    70,  137, 34,
};

/// Saturation is a straight line between grayscale and the original, extended
/// past both ends.
///
///     out = luma + s * (in - luma)
///
/// At `s = 0` that is the luma matrix; at `s = 256` the identity; above 256 it
/// extrapolates away from grey, which is what a saturation slider past 100%
/// does. Writing it as a matrix rather than as a special case is what lets it
/// compose with everything else here.
fn saturation(s: i32) Matrix {
    var m: Matrix = undefined;
    for (&m, identity, luma_matrix) |*out, i, l| {
        out.* = @divTrunc(s * i + (scale - s) * l, scale);
    }
    return m;
}

/// Matrix product, in the same fixed point. `compose(a, b)` applies `b` first.
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

    // Saturation moves chroma without moving luma, because the weights that
    // build the grey it interpolates against are the same weights that measure
    // brightness. The dump of a saturated image is nearly identical to the dump
    // of the original, and that is the correct result rather than a bug in the
    // dump.
    try out.writeAll("\nluma under saturation (original, sat 0, sat 200%)\n");
    for (samples) |s| {
        try out.print("{s:>13}: {d:>3} {d:>3} {d:>3}\n", .{
            s.name,
            canvas.luma(s.color),
            canvas.luma(transform(s.color, saturation(0))),
            canvas.luma(transform(s.color, saturation(512))),
        });
    }

    // Composition, and its cost. Two passes round to a byte twice; the composed
    // matrix rounds once, in the matrix product instead. The results are close
    // but not identical, which is the difference from a lookup table: composing
    // point operations on 8-bit channels is exact, composing matrices is not.
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

## Grayscale, written as a matrix

Put the luma weights in all three rows:

```zig
const luma_matrix: Matrix = .{
    77, 150, 29,
    77, 150, 29,
    77, 150, 29,
};
```

Every output channel becomes the same weighted average, which is grayscale.
The entries are scaled by 256 and the multiply divides by 256 at the end, so
this stays in integers throughout. Floats would buy precision that the final
cast to `u8` throws away, and cost a conversion at each end.

## Saturation is a line through grey

```
out = luma + s * (in - luma)
```

At `s = 0` that is grayscale, at `s = 1` the original, and above 1 it keeps
going in the same direction, away from grey. As a matrix it is a blend of the
luma matrix and the identity:

```zig
fn saturation(s: i32) Matrix {
    var m: Matrix = undefined;
    for (&m, identity, luma_matrix) |*out, i, l| {
        out.* = @divTrunc(s * i + (scale - s) * l, scale);
    }
    return m;
}
```

Writing it as a matrix rather than as a special case is what lets it compose
with the others.

There is a property worth noticing in the output. Saturation moves chroma and
leaves brightness alone:

```
luma under saturation (original, sat 0, sat 200%)
     red disc:  97  97  76
   green disc: 151 151 152
 yellow block: 212 212 209
```

Grayscale preserves luma exactly, because the grey it produces is defined as
the luma. At 200% the numbers drift, and the red disc drops from 97 to 76.
That is clipping, not a flaw in the maths. Extrapolating red past 100%
saturation pushes the channels into the wall, and a clipped colour no longer
has the luma the matrix asked for. Any saturation control pushed far enough
loses brightness in exactly the colours it was supposed to intensify.

## Sepia's rows do not sum to 256

```zig
const sepia: Matrix = .{
    101, 197, 48,
    89,  176, 43,
    70,  137, 34,
};
```

Those rows sum to 346, 308 and 241. A row summing to 256 preserves brightness;
these deliberately do not. Sepia is meant to lift the image as it tints it,
and the red row gains the most, which is where the warmth comes from. Getting
this matrix "wrong" in the direction of 256 gives a muddy grey-brown that
looks nothing like the effect.

It is worth knowing the difference, because a matrix that unintentionally sums
to more than 256 blows out highlights for no reason.

## Composition, and what it costs

The product of two colour matrices is the matrix that applies both:

```zig
fn compose(a: Matrix, b: Matrix) Matrix { ... }  // applies b first
```

Sepia after 62% saturation, as one matrix:

```
  +100 +198  +43
   +89 +177  +38
   +70 +138  +30
```

One pass over the image instead of two, and the saving grows with the length
of the chain. A photo app applying six adjustments does one multiply per
pixel, not six.

The composition is not exact:

```
two passes vs one composed matrix: 1560 of 2048 pixels differ, by at most 1
```

Two passes round to a byte in between; the composed matrix rounds once, inside
the matrix product. This is the difference from the lookup tables in
[per-pixel transforms](https://www.ziglang.in/learn/graphics/per-pixel/), where composing was exact
to the last bit. A table maps bytes to bytes and there is nowhere for an error
to hide. A matrix carries fractions, and rounding them earlier or later gives
different answers.

Off by one per channel is below what anyone can see, and it is the composed
version that is more accurate, since it rounds once instead of twice. Worth
knowing anyway, because it means "same filter, different order of operations"
does not give bit-identical output, and a test that compares images byte for
byte will fail on it.

## What a matrix cannot do

**Anything spatial.** A colour matrix reads one pixel. Blur, sharpen and edge
detection need neighbours, which is
[convolution](https://www.ziglang.in/learn/graphics/convolution/), a different loop with a different
cost.

**Anything non-linear.** Gamma, curves and thresholds are not linear functions of
the channels, so no matrix expresses them. Those are lookup tables, and a real
pipeline mixes both: tables for the curves, a matrix for the colour mixing.

**Alpha.** These are 3x3 over RGB. Systems that include alpha use a 4x5 (four
rows, four coefficients plus a constant offset), which is what the CSS
`feColorMatrix` filter and Android's `ColorMatrix` both take. The extra column
is what lets a matrix add a constant, and that is how tinting toward a fixed
colour works.

Everything on this page also multiplies sRGB bytes directly, with the same
caveat [alpha blending](https://www.ziglang.in/learn/graphics/blending/) sets out: those bytes are
not linear light. Colour operations that care convert to linear first.
