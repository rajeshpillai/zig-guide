# Alpha Blending

> Source-over compositing in integers, the reason for the /255, and the reason that order is still important.

Each chapter before this one draws a shape on top of the old pixels. A later
write replaces an earlier write. This method is the painter's algorithm, and
it is sufficient for opaque shapes. When the shape on top is not opaque, use
blending instead.

The standard operator is **source over destination**. It operates on one
channel at a time:

```
out = (src * a + dst * (255 - a)) / 255
```

At `a = 255`, the output is the source. At `a = 0`, the output does not
change. Between these two values, the output is a weighted average. The sum
of the weights is exactly one. Thus the blend alone never makes the result
brighter or darker.

```zig
const std = @import("std");
const canvas = @import("_canvas.zig");

var pixels: [canvas.width * canvas.height]u32 = undefined;

/// The source-over operator on one channel:
///
///     out = (src * a + dst * (255 - a)) / 255
///
/// The `+ 127` rounds to the nearest value. Without it, the division removes
/// the fraction. A division by 256 with a shift looks faster. But at a = 255
/// the shift gives 254. Thus blending code that uses the shift cannot make
/// pure white.
fn blendChannel(src: u8, dst: u8, a: u8) u8 {
    const s = @as(u32, src) * @as(u32, a);
    const d = @as(u32, dst) * (255 - @as(u32, a));
    return @intCast((s + d + 127) / 255);
}

fn blend(src: u32, dst: u32, a: u8) u32 {
    const s = canvas.channels(src);
    const d = canvas.channels(dst);
    return canvas.rgb(
        blendChannel(s.r, d.r, a),
        blendChannel(s.g, d.g, a),
        blendChannel(s.b, d.b, a),
    );
}

/// Read, blend, then write the result. The difference from `putPixel` is that
/// the destination is now an input. A later draw does not erase an earlier
/// draw, and the order of the draws changes the result.
fn blendPixel(x: i32, y: i32, color: u32, a: u8) void {
    if (x < 0 or y < 0) return;
    const ux: usize = @intCast(x);
    const uy: usize = @intCast(y);
    if (ux >= canvas.width or uy >= canvas.height) return;

    const i = uy * canvas.width + ux;
    pixels[i] = blend(color, pixels[i], a);
}

fn blendCircle(cx: i32, cy: i32, r: i32, color: u32, a: u8) void {
    var y = cy - r;
    while (y <= cy + r) : (y += 1) {
        var x = cx - r;
        while (x <= cx + r) : (x += 1) {
            const dx = x - cx;
            const dy = y - cy;
            if (dx * dx + dy * dy <= r * r) blendPixel(x, y, color, a);
        }
    }
}

pub fn main(init: std.process.Init) !void {
    var buf: [8192]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    for (0..canvas.height) |y| {
        for (0..canvas.width) |x| {
            const g: u8 = @intCast((x * 90) / (canvas.width - 1));
            canvas.putPixel(&pixels, @intCast(x), @intCast(y), canvas.rgb(20, g, 60));
        }
    }

    // Three discs at 60% opacity. Where two discs overlap, the background
    // shows through both discs. The overlap is brighter than each disc alone.
    blendCircle(24, 13, 11, canvas.rgb(255, 80, 80), 153);
    blendCircle(40, 13, 11, canvas.rgb(80, 255, 120), 153);
    blendCircle(32, 24, 11, canvas.rgb(120, 160, 255), 153);

    try canvas.dump(out, &pixels);

    const white = canvas.rgb(255, 255, 255);
    const black = canvas.rgb(0, 0, 0);

    try out.writeAll("\nwhite over black:\n");
    for ([_]u8{ 0, 64, 128, 192, 255 }) |a| {
        const result = canvas.channels(blend(white, black, a));
        try out.print("  a={d:>3} -> {d:>3} (shift-by-256 would give {d:>3})\n", .{
            a, result.r, (@as(u32, 255) * a) >> 8,
        });
    }

    // Blending is not commutative. Half of red on top of blue is not equal to
    // half of blue on top of red. Thus the draw order is still important.
    const red = canvas.rgb(255, 0, 0);
    const blue = canvas.rgb(0, 0, 255);
    const r_over_b = canvas.channels(blend(red, blue, 64));
    const b_over_r = canvas.channels(blend(blue, red, 64));
    try out.print("\nred over blue  at a=64: {d} {d} {d}\n", .{ r_over_b.r, r_over_b.g, r_over_b.b });
    try out.print("blue over red  at a=64: {d} {d} {d}\n", .{ b_over_r.r, b_over_r.g, b_over_r.b });

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`09-graphics.blending`)*

## Do not skip the division

A division by 256 with a shift is faster than a division by 255. But the
error is visible:

```zig
(255 * a) >> 8   // a = 255 gives 254, not 255
```

The output above shows both columns. An opaque white composite gives 254.
For this reason, much older blending code cannot make pure white. The error
increases each time that you blend onto the same pixel again.

The expression `(s + d + 127) / 255` rounds to the nearest value. The cost is
one division, and the compiler usually changes that division into a multiply
and a shift.

If you want a fast version that is also correct, the usual method is:

```zig
const t = @as(u32, src) * a + 128;
const blended: u8 = @intCast((t + (t >> 8)) >> 8);
```

This version is exact for all 8-bit inputs. Use it only when a profile shows
that the division is important.

## Read, blend, write

The only change in structure from `putPixel` is that the destination is now
an input:

```zig
const i = uy * width + ux;
pixels[i] = blend(color, pixels[i], a);
```

With this one change, the draw order changes the colour. Before, the draw
order decided only which shape hid which shape.

In the output, three discs at 60% opacity overlap. Each overlap has a
different colour, because each overlap is the result of two blends in
sequence.

## Blending is not commutative

The snippet composites red over blue and blue over red at the same alpha. The
two answers are different. For this reason, renderers draw from back to
front. If a renderer draws translucent geometry in a random order, the
colours are also random.

Use one of these methods:

- Sort by depth, and draw from far to near.
- Use an order-independent technique.

## Premultiplied alpha

The operator above is the simple model, and the model has a known weakness.
Some operations use colours that carry their own alpha: filters, changes of
scale, and averages. These operations give wrong results at the edges. The
cause is that a fully transparent pixel still adds its colour to the average.

**Premultiplied alpha** stores `(r*a, g*a, b*a, a)` instead. Then the
operator needs one less multiply:

```
out = src + dst * (255 - a) / 255
```

Systems that scale or filter use premultiplied alpha for this reason, for
example a GPU, a compositor or a browser. The cost is a conversion at the
boundary, because most image files store straight alpha.

## sRGB bytes are not linear light

All the code on this page averages the bytes as the file stores them. These
bytes are not linear light. sRGB applies a transfer curve of approximately
`x^2.2`. Thus a value of 128 is about 22% of the light of 255, not 50%.

A blend in sRGB space makes a 50% composite of black and white too dark. The
eye expects a lighter result, and the difference is visible.

To blend correctly, convert to linear, blend, and then convert the result to
sRGB again.
Alternatively, use 16-bit linear values for all steps.
[Linear Light](https://www.ziglang.in/learn/graphics/linear-light/) builds both conversions as
lookup tables.

Almost all 8-bit graphics code blends in sRGB and accepts the error. The code
on this page also does this. This tradeoff is deliberate. In your code, make
sure that a blend in sRGB is a choice and not a mistake.
