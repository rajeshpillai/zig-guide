# Per-Pixel Transforms

> Brightness, contrast, threshold and invert are all one table lookup, and the add that does brightness is where Zig has an opinion.

Everything up to here drew into an empty buffer. The rest of this section
reads a buffer that already has a picture in it and writes back a changed one.

The simplest kind reads exactly one pixel to produce one pixel. Brightness,
contrast, invert, threshold, gamma and every colour curve are point
operations, and they share a property worth exploiting. On 8-bit channels
there are only 256 possible inputs, so there are only 256 possible answers.
Compute them once into an array and the filter becomes an array index.

```zig
const Lut = [256]u8;

fn apply(buf: []u32, lut: Lut) void {
    for (buf) |*p| {
        const c = canvas.channels(p.*);
        p.* = canvas.rgb(lut[c.r], lut[c.g], lut[c.b]);
    }
}
```

That loop is the entire family. The difference between brightness and
threshold is 256 bytes of data, not code.

```zig
const std = @import("std");
const canvas = @import("_canvas.zig");

var pixels: [canvas.width * canvas.height]u32 = undefined;

/// Every answer a point operation can give, indexed by the input value.
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

/// Brightness is an add, and the add is the interesting part.
///
/// `+|` and `-|` are saturating: they clamp at the type's bounds instead of
/// wrapping. Plain `+` on a `u8` at 250 + 10 is illegal behaviour in Zig and
/// traps in a safe build, and `+%` would wrap 250 + 10 round to 4, which is how
/// a naive brightness filter puts black speckles in a white sky.
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

/// Contrast pivots around mid-grey: values above 128 move up, values below move
/// down, and 128 stays put. `factor` is scaled by 256, so 256 is no change and
/// 512 is double contrast.
///
/// This one genuinely can overflow in both directions, so it clamps in a wider
/// type rather than saturating in `u8`. Saturating a `u8` cannot help when the
/// intermediate is already negative.
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

/// Two tables become one. `compose(b, a)` is "apply a, then b", so a chain of
/// point operations costs one table build and one pass over the image no matter
/// how long the chain gets.
fn compose(second: Lut, first: Lut) Lut {
    var lut: Lut = undefined;
    for (&lut, 0..) |*v, i| v.* = second[first[i]];
    return lut;
}

/// One pass, three lookups. The image is the loop bound; the table is not.
fn apply(buf: []u32, lut: Lut) void {
    for (buf) |*p| {
        const c = canvas.channels(p.*);
        p.* = canvas.rgb(lut[c.r], lut[c.g], lut[c.b]);
    }
}

/// Grayscale is the point operation that is *not* a per-channel table: the
/// output channel depends on all three inputs, so there are 2^24 possible
/// answers rather than 256.
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

    // Lift, then stretch around mid-grey. Built as one table, applied once.
    // The background ramp is pushed to black and the block to white: contrast
    // does not create detail, it spends the range it has on the middle.
    const chain = compose(contrast(400), brightness(30));
    apply(&pixels, chain);
    try out.writeAll("\nbrightness(+30) then contrast(x1.56):\n");
    try canvas.dump(out, &pixels);

    // A table is worth printing. These five columns are entire filters.
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

    // Saturating versus wrapping, on the one value where it shows.
    const near_white: u8 = 250;
    try out.print("\n250 +| 10 = {d}   250 +% 10 = {d}\n", .{
        near_white +| @as(u8, 10),
        near_white +% @as(u8, 10),
    });

    // Composition is exact, not an approximation: the table built from two
    // tables gives the same answer as running both passes.
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

## The add is the interesting part

Brightness adds a constant. On a `u8` at 250, adding 10 has three possible
meanings and Zig makes you pick:

```zig
value + 10    // illegal behaviour: traps in a safe build
value +% 10   // wraps: 250 + 10 = 4
value +| 10   // saturates: 250 + 10 = 255
```

Only the third is right here. The second is the bug that puts black speckles
in a brightened sky, and it is the default in C, where unsigned overflow is
defined to wrap and nothing warns. The first is the one most people want as a
default and no language gives them, because there is no sensible value to
return.

`+|` and `-|` are language operators, not library calls, and they compile to a
single instruction on every target that has one. [Integer
Rules](https://www.ziglang.in/learn/language-basics/integer-rules/) covers the full set.

Contrast cannot use them. It pivots around mid-grey:

```zig
const centred = @as(i32, value) - 128;
const scaled = @divTrunc(centred * factor, 256) + 128;
lut[i] = @intCast(std.math.clamp(scaled, 0, 255));
```

The intermediate goes negative for dark pixels, and a saturating `u8`
operation cannot help with a value that was never a `u8`. Widen, clamp,
narrow. That order is not optional.

## Grayscale is the exception

It looks like a point operation and it is, but the output channel depends on
all three inputs, so there is no 256-entry table for it. There are 2^24
possible inputs.

The weights are also not thirds:

```
luma = (77*R + 150*G + 29*B) / 256
```

Those are the Rec. 601 coefficients, scaled so the divide is a shift. Green
carries roughly 59% of perceived brightness and blue about 11%, because the
eye is far more sensitive to green. Averaging the three channels equally gives
a grayscale image where reds and blues come out too light and the whole thing
looks flat. The snippet prints both numbers for the red disc: 97 by luma, 103
by average.

## Chains collapse

Two tables become one:

```zig
fn compose(second: Lut, first: Lut) Lut {
    var lut: Lut = undefined;
    for (&lut, 0..) |*v, i| v.* = second[first[i]];
    return lut;
}
```

Brightness then contrast then threshold is one table build and one pass over
the image, however long the chain gets. The snippet checks this: the composed
table matches running both passes at all 256 inputs, exactly, with no rounding
to argue about. Every step maps bytes to bytes, so there is nowhere for an
error to hide.

That exactness is specific to point operations on 8-bit channels. The [colour
matrices](https://www.ziglang.in/learn/graphics/color-matrix/) in a later chapter also compose, and
they do not compose exactly.

## Contrast does not create detail

The second dump in the output is the scene brightened and then stretched. The
background ramp is pushed to black and the yellow block to white, and neither
comes back. Contrast spends the available range on the middle of the histogram
and takes it from the ends. Pixels that clip at 0 or 255 are identical
afterwards, no matter how different they were before.

This is why editing pipelines that care keep more than 8 bits per channel
until the last step. At 8 bits every filter in the chain rounds, and the
rounding is not recoverable.
