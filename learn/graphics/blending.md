# Alpha Blending

> Source-over compositing in integers, why the /255 matters, and why order still does.

Every chapter so far has drawn by overwriting. Later writes replace earlier
ones. This is the painter's algorithm, and it is all you need for opaque
shapes. When the shape on top is not opaque, blending replaces it.

The standard operator is **source over destination**, one channel at a time:

```
out = (src * a + dst * (255 - a)) / 255
```

At `a = 255` the output is the source. At `a = 0` nothing happens. In between
it is a weighted average. The weights sum to exactly one, so the result never
brightens or darkens on its own.

```zig
const std = @import("std");
const canvas = @import("_canvas.zig");

var pixels: [canvas.width * canvas.height]u32 = undefined;

/// Source-over compositing on one channel:
///
///     out = (src * a + dst * (255 - a)) / 255
///
/// The `+ 127` rounds to nearest instead of truncating. Dividing by 256 with a
/// shift looks like a faster choice, but at a = 255 it returns 254, so blending
/// code that does it cannot reach pure white.
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

/// Read, blend, write back. The difference from `putPixel` is that the
/// destination is now an input. A later draw no longer erases an earlier one,
/// and the order of the draws changes the result.
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

    // Three discs at 60% opacity. Where two overlap the background shows
    // through both, and the overlap is brighter than either disc alone.
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

    // Blending is not commutative. Half of red on top of blue is not half of
    // blue on top of red. Because of this, draw order still matters.
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

## The division you should not skip

Dividing by 256 with a shift is faster than dividing by 255, but the error is
visible:

```zig
(255 * a) >> 8   // a = 255 gives 254, not 255
```

The output above prints both columns. An opaque white composite lands on 254.
This is why a lot of older blending code cannot reach pure white. The error
compounds every time you blend onto the same pixel again. `(s + d + 127) /
255` rounds to nearest and costs one division the compiler usually turns into
a multiply and a shift anyway.

If you want a fast version that is also correct, the usual method is:

```zig
const t = @as(u32, src) * a + 128;
const blended: u8 = @intCast((t + (t >> 8)) >> 8);
```

That is exact for all 8-bit inputs. Use it only when a profile shows the
division matters.

## Read, blend, write

The only structural difference from `putPixel` is that the destination is now
an input:

```zig
const i = uy * width + ux;
pixels[i] = blend(color, pixels[i], a);
```

With that one change, draw order affects the colour, instead of only deciding
which shape hides which. Three discs at 60% opacity overlap in the output.
Each overlap is a distinct colour, because it is the result of two blends in
sequence.

## Blending is not commutative

The snippet composites red over blue and blue over red at the same alpha, and
gets different answers. This is why renderers draw back to front. A renderer
that draws translucent geometry in arbitrary order produces arbitrary colours.
Sort by depth, draw far to near, or use an order-independent technique.

## Where premultiplied alpha comes in

The operator above is the simple model, and it has a known weakness. Filtering, scaling, or
averaging colours that carry their own alpha gives wrong results at the edges,
because a fully transparent pixel still contributes its colour to the average.

**Premultiplied alpha** stores `(r*a, g*a, b*a, a)` instead, and the operator
loses a multiply:

```
out = src + dst * (255 - a) / 255
```

Compositing systems that scale or filter (a GPU, a compositor, a browser) use
premultiplied alpha for this reason. It costs a conversion at the boundary,
since most image files store straight alpha.

## sRGB bytes are not linear light

Everything on this page averages the bytes as stored. Those bytes are not
linear light: sRGB applies a transfer curve of roughly `x^2.2`, so a value of
128 is about 22% of the light of 255, not 50%. Blending in that space makes a
50% composite of black and white come out visibly darker than the eye expects.

Doing it correctly means converting to linear, blending, and converting back,
or working in 16-bit linear throughout. Nearly all 8-bit graphics code,
including this page, blends in sRGB anyway and accepts the error. That is a
deliberate tradeoff. Make sure it is a choice in your code, and not a mistake.
