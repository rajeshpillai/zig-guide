# Per-Pixel Transforms

> Brightness, contrast, threshold and invert are all one table lookup, and brightness needs Zig's saturating add.

All the chapters before this one draw into an empty buffer. The other
chapters of this section read a buffer that already has a picture in it.
Then they write a changed picture back.

The simplest type of filter reads exactly one pixel to make one pixel.
Brightness, contrast, invert, threshold, gamma and all colour curves are
point operations. Point operations share a useful property:

- An 8-bit channel has only 256 possible inputs.
- Thus there are only 256 possible answers.
- Calculate the answers one time into an array. Then the filter is an array
  index.

```zig
const Lut = [256]u8;

fn apply(buf: []u32, lut: Lut) void {
    for (buf) |*p| {
        const c = canvas.channels(p.*);
        p.* = canvas.rgb(lut[c.r], lut[c.g], lut[c.b]);
    }
}
```

This loop runs all filters of this type. Brightness and threshold use the
same code. The only difference is 256 bytes of data.

```zig
const std = @import("std");
const canvas = @import("_canvas.zig");

var pixels: [canvas.width * canvas.height]u32 = undefined;

/// All the answers that a point operation can give. The index is the input
/// value.
const Lut = [256]u8;

fn identity() Lut {
    var lut: Lut = undefined;
    for (&lut, 0..) |*v, i| v.* = @intCast(i);
    return lut;
}

fn invert() Lut {
    var lut: Lut = undefined;
    for (&lut, 0..) |*v, i| v.* = @intCast(255 - i);
    return lut;
}

/// Brightness is an add, and the type of add decides the result.
///
/// `+|` and `-|` are saturating operators. They clamp at the limits of the
/// type, and they do not wrap. In Zig, plain `+` on a `u8` at 250 + 10 is
/// illegal behaviour, and it traps in a safe build. `+%` wraps 250 + 10 to 4.
/// A brightness filter that wraps puts black spots in a white sky.
fn brightness(delta: i16) Lut {
    var lut: Lut = undefined;
    for (&lut, 0..) |*v, i| {
        const value: u8 = @intCast(i);
        v.* = if (delta >= 0)
            value +| @as(u8, @intCast(delta))
        else
            value -| @as(u8, @intCast(-delta));
    }
    return lut;
}

/// Contrast pivots around mid-grey. Values above 128 increase, values below
/// 128 decrease, and 128 does not change. The scale of `factor` is 256. Thus
/// 256 is no change, and 512 is double contrast.
///
/// Contrast can overflow in both directions. Thus this function clamps in a
/// wider type, and it does not saturate in `u8`. A saturating `u8` operation
/// cannot help when the intermediate value is already negative.
fn contrast(factor: i32) Lut {
    var lut: Lut = undefined;
    for (&lut, 0..) |*v, i| {
        const centred = @as(i32, @intCast(i)) - 128;
        const scaled = @divTrunc(centred * factor, 256) + 128;
        v.* = @intCast(std.math.clamp(scaled, 0, 255));
    }
    return lut;
}

fn threshold(cut: u8) Lut {
    var lut: Lut = undefined;
    for (&lut, 0..) |*v, i| v.* = if (i >= cut) 255 else 0;
    return lut;
}

/// Two tables become one table. `compose(b, a)` is "apply a, then b". Thus a
/// chain of point operations costs one table build and one pass over the
/// image. The length of the chain does not change this cost.
fn compose(second: Lut, first: Lut) Lut {
    var lut: Lut = undefined;
    for (&lut, 0..) |*v, i| v.* = second[first[i]];
    return lut;
}

/// One pass, three lookups. The image sets the loop bound. The table does
/// not set the loop bound.
fn apply(buf: []u32, lut: Lut) void {
    for (buf) |*p| {
        const c = canvas.channels(p.*);
        p.* = canvas.rgb(lut[c.r], lut[c.g], lut[c.b]);
    }
}

/// Grayscale is the point operation that is *not* a table for each channel.
/// The output channel depends on all three inputs. Thus there are 2^24
/// possible inputs, not 256.
fn grayscale(buf: []u32) void {
    for (buf) |*p| {
        const y: u8 = @intCast(canvas.luma(p.*));
        p.* = canvas.rgb(y, y, y);
    }
}

pub fn main(init: std.process.Init) !void {
    var buf: [16384]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    canvas.scene(&pixels);
    try out.writeAll("original:\n");
    try canvas.dump(out, &pixels);

    // Increase the brightness, then stretch around mid-grey. The code builds
    // one table and applies it one time. The background ramp becomes black,
    // and the block becomes white. Contrast adds no detail. Contrast gives
    // more of the output range to the middle values.
    const chain = compose(contrast(400), brightness(30));
    apply(&pixels, chain);
    try out.writeAll("\nbrightness(+30) then contrast(x1.56):\n");
    try canvas.dump(out, &pixels);

    // Print the table. Each of these five columns is a complete filter.
    const tables = [_]struct { name: []const u8, lut: Lut }{
        .{ .name = "ident", .lut = identity() },
        .{ .name = "invert", .lut = invert() },
        .{ .name = "+40", .lut = brightness(40) },
        .{ .name = "x2", .lut = contrast(512) },
        .{ .name = "thresh", .lut = threshold(128) },
    };
    try out.writeAll("\n  in |");
    for (tables) |t| try out.print(" {s:>6}", .{t.name});
    try out.writeByte('\n');
    for ([_]u8{ 0, 64, 128, 192, 255 }) |v| {
        try out.print(" {d:>3} |", .{v});
        for (tables) |t| try out.print(" {d:>6}", .{t.lut[v]});
        try out.writeByte('\n');
    }

    // Saturation compared with wraparound, on one value that shows the
    // difference.
    const near_white: u8 = 250;
    try out.print("\n250 +| 10 = {d}   250 +% 10 = {d}\n", .{
        near_white +| @as(u8, 10),
        near_white +% @as(u8, 10),
    });

    // Composition is exact. It is not an approximation. The table from two
    // tables gives the same answer as the two passes.
    const a = brightness(30);
    const b = contrast(400);
    var mismatches: usize = 0;
    for (0..256) |i| {
        if (compose(b, a)[i] != b[a[i]]) mismatches += 1;
    }
    try out.print("composed table differs from two passes at {d} of 256 inputs\n", .{mismatches});

    canvas.scene(&pixels);
    grayscale(&pixels);
    const before = canvas.channels(canvas.rgb(230, 40, 40));
    try out.print("\nluma of the red disc: {d} (not (r+g+b)/3 = {d})\n", .{
        canvas.luma(canvas.rgb(230, 40, 40)),
        (@as(u32, before.r) + before.g + before.b) / 3,
    });

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`09-graphics.per-pixel`)*

## Brightness needs a saturating add

Brightness adds a constant. For a `u8` with the value 250, an add of 10 has
three possible meanings, and Zig makes you select one:

```zig
value + 10    // illegal behaviour: traps in a safe build
value +% 10   // wraps: 250 + 10 = 4
value +| 10   // saturates: 250 + 10 = 255
```

Only the third operator is correct here:

- The second operator is the bug that puts black spots in a brightened sky.
  The second operator is the default in C. In C, an unsigned overflow wraps
  by definition, and no warning occurs.
- The first operator asks for the true sum, 260. A `u8` cannot hold 260, thus
  no `u8` value is a correct result. A safe build stops the program.

`+|` and `-|` are operators of the language. They compile to a single
instruction on each target that has such an instruction.
[Integer Rules](https://www.ziglang.in/learn/language-basics/integer-rules/) explains the full set.

Contrast cannot use these operators, because contrast pivots around
mid-grey:

```zig
const centred = @as(i32, value) - 128;
const scaled = @divTrunc(centred * factor, 256) + 128;
lut[i] = @intCast(std.math.clamp(scaled, 0, 255));
```

For dark pixels, the intermediate value is negative. A saturating `u8`
operation cannot help with a value that was never a `u8`. Thus the code
does these steps in this order:

1. Change the value to `i32`.
2. Clamp the value to 0..255.
3. Change the value back to `u8`.

A different order gives wrong results.

## Grayscale is the exception

Grayscale is a point operation. But each output channel depends on all three
inputs. Thus a table of 256 entries cannot hold grayscale, because there are
2^24 possible inputs.

Also, the weights are not one third each:

```
luma = (77*R + 150*G + 29*B) / 256
```

These weights are the Rec. 601 coefficients, with a scale that changes the
division into a shift. Green gives approximately 59% of the brightness that
the eye sees, and blue gives about 11%. The reason is that the eye is much
more sensitive to green.

If you average the three channels equally, reds and blues are too light in
the grayscale image. The full image then looks flat. The snippet shows both
numbers for the red disc: 97 with luma, and 103 with the average.

## A chain becomes one table

Two tables become one table:

```zig
fn compose(second: Lut, first: Lut) Lut {
    var lut: Lut = undefined;
    for (&lut, 0..) |*v, i| v.* = second[first[i]];
    return lut;
}
```

Brightness, then contrast, then threshold is one table build and one pass
over the image. The length of the chain does not change this cost.

The snippet checks this result. At all 256 inputs, the composed table gives
exactly the same values as the two passes. There is no difference from
rounding. Each step maps bytes to bytes, thus the composition adds no error.

Only point operations on 8-bit channels have this exact result. The
[colour matrices](https://www.ziglang.in/learn/graphics/color-matrix/) in a later chapter also
compose, but their composition is not exact.

## Contrast does not create detail

The second dump in the output shows the scene after a brightness change and
then a contrast stretch. The background ramp becomes black, and the yellow
block becomes white. Neither area returns to its old values.

Contrast gives more of the available range to the middle of the histogram,
and it takes that range from the ends. Pixels that clip at 0 or 255 become
identical. The pixels stay identical, however different they were before.

For this reason, image editors that must keep the quality high use more than
8 bits for each channel until the last step. At 8 bits, each filter in the
chain rounds, and you cannot recover from the rounding.
