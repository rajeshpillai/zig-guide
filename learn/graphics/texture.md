# Texture Mapping

> The triangle already interpolates. Point it at a second image and it interpolates coordinates into that instead of colours.

[Rasterizing triangles](https://www.ziglang.in/learn/graphics/triangles/) ended with three
barycentric weights and the observation that they interpolate anything you
attach to the corners. That chapter attached colours. Attach a pair of
coordinates into another image instead and the triangle is textured, and not
one line of the rasteriser changes to make it happen.

## The program

```zig
const std = @import("std");

const dst_width: usize = 60;
const dst_height: usize = 16;

var framebuffer: [dst_width * dst_height]u32 = undefined;

fn rgb(r: u8, g: u8, b: u8) u32 {
    return (@as(u32, r) << 16) | (@as(u32, g) << 8) | @as(u32, b);
}

const backdrop = rgb(0, 0, 0);
const dark = rgb(40, 44, 52);
const light = rgb(240, 246, 243);
const amber = rgb(247, 164, 29);

/// The canvas from the previous chapter, trimmed to what this one uses. It is
/// the thing being written to, so it carries a stride.
const Canvas = struct {
    pixels: []u32,
    width: usize,
    height: usize,
    stride: usize,

    fn set(self: Canvas, x: usize, y: usize, color: u32) void {
        if (x >= self.width or y >= self.height) return;
        self.pixels[y * self.stride + x] = color;
    }

    fn fill(self: Canvas, color: u32) void {
        for (0..self.height) |y| {
            for (0..self.width) |x| self.set(x, y, color);
        }
    }
};

/// A texture is only ever read, so it has no stride: nothing samples a
/// rectangle out of the middle of one. Giving it its own type rather than
/// reusing `Canvas` is a claim about direction, and the compiler enforces it,
/// because a `Texture` has no `set`.
const Texture = struct {
    pixels: []const u32,
    width: usize,
    height: usize,
};

var texels: [8 * 8]u32 = undefined;

/// Two-texel checks, so the pattern survives being scaled down, and one amber
/// corner, so a tile that has been flipped or wrapped is obvious rather than
/// merely different.
fn buildTexture() Texture {
    for (0..8) |y| {
        for (0..8) |x| {
            const check = ((x / 2) + (y / 2)) % 2 == 0;
            texels[y * 8 + x] = if (check) light else dark;
        }
    }
    for (0..2) |y| {
        for (0..2) |x| texels[y * 8 + x] = amber;
    }
    return .{ .pixels = &texels, .width = 8, .height = 8 };
}

/// A corner of a triangle: where it lands on the canvas, and where it reads
/// from in the texture. `u` and `v` run 0 to 1 across the image regardless of
/// how many pixels the image has, which is what lets the same coordinates
/// address a texture of any size.
const Vertex = struct { x: f32, y: f32, u: f32, v: f32 };

/// Twice the signed area of the triangle abp. Positive on one side of the line
/// ab and negative on the other, which is the whole test.
fn edge(ax: f32, ay: f32, bx: f32, by: f32, px: f32, py: f32) f32 {
    return (bx - ax) * (py - ay) - (by - ay) * (px - ax);
}

/// Nearest-neighbour sampling. `wrap` decides what a coordinate outside 0..1
/// means: repeat the image, or hold the edge texel.
fn sample(tex: Texture, u: f32, v: f32, wrap: bool) u32 {
    const w: i32 = @intCast(tex.width);
    const h: i32 = @intCast(tex.height);
    var tx: i32 = @intFromFloat(@floor(u * @as(f32, @floatFromInt(w))));
    var ty: i32 = @intFromFloat(@floor(v * @as(f32, @floatFromInt(h))));

    if (wrap) {
        // `@mod`, not `%`: the remainder operator keeps the sign of the
        // dividend, so a u of -0.1 would index backwards out of the texture.
        tx = @mod(tx, w);
        ty = @mod(ty, h);
    } else {
        tx = @max(0, @min(w - 1, tx));
        ty = @max(0, @min(h - 1, ty));
    }

    return tex.pixels[@intCast(ty * w + tx)];
}

/// The same barycentric rasteriser as the triangles chapter, with one change:
/// the three weights interpolate `u` and `v` instead of a colour.
fn triangle(dst: Canvas, tex: Texture, a: Vertex, b: Vertex, c: Vertex, wrap: bool) void {
    const area = edge(a.x, a.y, b.x, b.y, c.x, c.y);
    if (area == 0) return;

    const min_x: usize = @intFromFloat(@max(0, @floor(@min(a.x, @min(b.x, c.x)))));
    const min_y: usize = @intFromFloat(@max(0, @floor(@min(a.y, @min(b.y, c.y)))));
    const max_x: usize = @intFromFloat(@max(0, @ceil(@max(a.x, @max(b.x, c.x)))));
    const max_y: usize = @intFromFloat(@max(0, @ceil(@max(a.y, @max(b.y, c.y)))));

    var y = min_y;
    while (y <= max_y and y < dst.height) : (y += 1) {
        var x = min_x;
        while (x <= max_x and x < dst.width) : (x += 1) {
            // Sample at the pixel's centre, which is what stops a shared edge
            // between two triangles from dropping a line of pixels.
            const px = @as(f32, @floatFromInt(x)) + 0.5;
            const py = @as(f32, @floatFromInt(y)) + 0.5;

            const w0 = edge(b.x, b.y, c.x, c.y, px, py) / area;
            const w1 = edge(c.x, c.y, a.x, a.y, px, py) / area;
            const w2 = edge(a.x, a.y, b.x, b.y, px, py) / area;
            if (w0 < 0 or w1 < 0 or w2 < 0) continue;

            // The interpolation. Three weights, applied to the corners' texture
            // coordinates exactly as they would be to their colours.
            const u = w0 * a.u + w1 * b.u + w2 * c.u;
            const v = w0 * a.v + w1 * b.v + w2 * c.v;
            dst.set(x, y, sample(tex, u, v, wrap));
        }
    }
}

/// Four corners, two triangles, sharing the diagonal.
fn quad(dst: Canvas, tex: Texture, corners: [4]Vertex, wrap: bool) void {
    triangle(dst, tex, corners[0], corners[1], corners[2], wrap);
    triangle(dst, tex, corners[0], corners[2], corners[3], wrap);
}

const ramp = " .:-=+*#%@";

fn dump(canvas: Canvas, out: *std.Io.Writer) !void {
    var row: [dst_width]u8 = undefined;
    for (0..canvas.height) |y| {
        for (0..canvas.width) |x| {
            const color = canvas.pixels[y * canvas.stride + x];
            const luma = (((color >> 16) & 0xff) * 77 +
                ((color >> 8) & 0xff) * 150 +
                (color & 0xff) * 29) >> 8;
            row[x] = ramp[(luma * (ramp.len - 1)) / 255];
        }
        try out.writeAll(std.mem.trimEnd(u8, row[0..canvas.width], " "));
        try out.writeByte('\n');
    }
}

pub fn main(init: std.process.Init) !void {
    var buf: [8192]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    const tex = buildTexture();
    const dst = Canvas{
        .pixels = &framebuffer,
        .width = dst_width,
        .height = dst_height,
        .stride = dst_width,
    };

    // Left: the image once, corner to corner. Right: the same rectangle with
    // coordinates running to 2 instead of 1, so the sampler walks off the edge
    // of the texture twice in each direction and wrapping brings it back.
    dst.fill(backdrop);
    quad(dst, tex, .{
        .{ .x = 2, .y = 0, .u = 0, .v = 0 },
        .{ .x = 26, .y = 0, .u = 1, .v = 0 },
        .{ .x = 26, .y = 16, .u = 1, .v = 1 },
        .{ .x = 2, .y = 16, .u = 0, .v = 1 },
    }, false);
    quad(dst, tex, .{
        .{ .x = 32, .y = 0, .u = 0, .v = 0 },
        .{ .x = 56, .y = 0, .u = 2, .v = 0 },
        .{ .x = 56, .y = 16, .u = 2, .v = 2 },
        .{ .x = 32, .y = 16, .u = 0, .v = 2 },
    }, true);
    try out.writeAll("uv 0..1, and uv 0..2 wrapped\n");
    try dump(dst, out);

    // A trapezoid: the top edge is shorter than the bottom, so no single
    // affine map covers all four corners. Each triangle gets its own, and the
    // shared diagonal is where the two disagree.
    dst.fill(backdrop);
    quad(dst, tex, .{
        .{ .x = 19, .y = 0, .u = 0, .v = 0 },
        .{ .x = 41, .y = 0, .u = 1, .v = 0 },
        .{ .x = 57, .y = 16, .u = 1, .v = 1 },
        .{ .x = 3, .y = 16, .u = 0, .v = 1 },
    }, false);
    try out.writeAll("\nthe same uv on a trapezoid, and the seam it produces\n");
    try dump(dst, out);

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`09-graphics.texture`)*

## What just happened

**The interpolation is the same three weights.** `w0`, `w1` and `w2` are
computed exactly as they were for Gouraud shading. The only edit is what they
are multiplied by:

```zig
const u = w0 * a.u + w1 * b.u + w2 * c.u;
const v = w0 * a.v + w1 * b.v + w2 * c.v;
```

**Coordinates run 0 to 1, not 0 to 8.** The texture is 8 pixels square and
nothing outside `sample` mentions that. Normalized coordinates mean the same
four corners address a 16 pixel texture, or a 4096 pixel one, without the
geometry knowing which it got.

**Going past 1 is a decision, not an error.** The right-hand square asks for
coordinates up to 2. Wrapping turns that into the image twice in each
direction. Clamping would have stretched the edge texels into a smear. Both
are reasonable and the sampler has to be told which.

**The trapezoid has a seam.** Look along its diagonal. A four-cornered shape is drawn as two triangles, and each gets its own affine
interpolation. When the shape is not a parallelogram, those two maps do not
agree along the edge they share.

## The seam is not a bug in the rasteriser

It is the honest result of what an affine map can represent. A triangle's
three corners fix a linear relationship between position and texture
coordinate exactly, with nothing left over. Four corners are one constraint
too many, so splitting into two triangles solves two separate problems and the
answers meet at the diagonal without matching.

Draw a parallelogram instead and the seam disappears, because there a single
affine map does satisfy all four corners and the two triangles agree by
construction.

This is the same defect as perspective in 3D, seen in 2D where it is easier to
look at. A wall receding into the distance is a trapezoid on the screen, so
texture coordinates vary non-linearly across it. Interpolating them linearly
is what produced the wobbling floors in games of the mid nineties. The fix is
to interpolate the reciprocals along with the coordinates and divide at each
pixel. That is what "perspective correct" means, and why it cost more than the
hardware of the day wanted to spend.

## Why a texture is not a canvas

`Texture` here is its own type, with `pixels`, `width` and `height` and no
`stride`. That is a deliberate difference from [the
canvas](https://www.ziglang.in/learn/graphics/sub-canvas/), and it says something true. Nothing in
this program samples a rectangle out of the middle of a larger image, so there
is no second width to carry.

It buys a real guarantee. `Texture` has no `set`, and its pixels are `[]const
u32`, so the direction of travel is in the type rather than in a comment.
Passing the destination where the source belongs does not compile.

The alternative, one type used for both ends, is what olive.c does, and it is
not wrong. It makes a rendered canvas immediately usable as a texture, which
is how render-to-texture works and how a compositor treats a window. The cost
is that nothing stops you writing through a handle you meant only to read.

## Check yourself

The sampler floors the scaled coordinate to pick a texel. What happens at
exactly `u = 1.0` with wrapping turned off?

`u * 8` is `8`, flooring gives `8`, and the texture's last valid index is `7`.
The clamp catches it and returns texel 7, which is why the branch reads
`@min(w - 1, tx)` and not `@min(w, tx)`.

No pixel in this program actually reaches it. `u` is exactly 1 only where the
weight of the `u = 0` corner is exactly 0, which is the line through the other
two corners, and for the left square that line is `x = 26`. Pixel centres sit
at half-integers, so they miss it by half a pixel every time.

That is worth knowing rather than reassuring. The guard is never exercised by
the picture above, so nothing here would notice if it were wrong. The snippet
you are looking at also ships with the bounds check compiled out. Move one
vertex to a half-integer and the read goes off the end of the texture. That is
a caught panic in a safety build, and a pixel of whatever follows it in memory
in this one.

## If you have written C

The rasteriser is the shape you would write in C, with one difference worth
naming: `@mod` rather than `%`.

C's `%` keeps the sign of the dividend, so `-1 % 8` is `-1`, and a texture
coordinate that drifts slightly negative indexes backwards out of the array.
The symptom is a single wrong row or column along one edge, which is easy to
mistake for an off-by-one in the geometry.

Zig does not let you write that by accident, and not because it picks the
other answer. `%` on signed integers is a compile error:

```
error: remainder division with 'i32' and 'i32': signed integers
and floats must use @rem or @mod
```

`@rem(-1, 8)` is `-1`, matching C. `@mod(-1, 8)` is `7`, taking the sign of
the divisor, which is the wrapping a sampler wants. Both exist, neither is the
default, and the operator that would have quietly chosen for you is gone.

Next: moving the shape rather than the pixels inside it.
