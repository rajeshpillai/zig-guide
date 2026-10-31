# Texture Mapping

> The triangle already interpolates. Point the triangle at a second image, and it interpolates coordinates into that image, not colours.

At the end of [the triangles chapter](https://www.ziglang.in/learn/graphics/triangles/), the triangle had three barycentric weights. That chapter also showed that the weights interpolate each value that you attach to the corners. That chapter attached colours. Attach a pair of coordinates into a different image instead, and the result is a textured triangle. No line of the rasteriser changes.

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

/// The canvas from the previous chapter, with only the parts that this
/// chapter uses. The program writes to the canvas, thus the canvas has a
/// stride.
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

/// The program only reads a texture, thus a texture has no stride: no code
/// samples a rectangle from the middle of a texture. A separate type, not
/// `Canvas`, shows that data only comes out of a texture. The compiler makes
/// sure of that rule, because a `Texture` has no `set`.
const Texture = struct {
    pixels: []const u32,
    width: usize,
    height: usize,
};

var texels: [8 * 8]u32 = undefined;

/// Checks that are two texels wide, thus the pattern stays visible when the
/// program scales the texture down. One amber corner shows when a tile flips
/// or wraps.
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

/// A corner of a triangle: its position on the canvas, and the position that
/// it reads in the texture. `u` and `v` go from 0 to 1 across the image, for
/// any number of pixels in the image. Thus the same coordinates address a
/// texture of any size.
const Vertex = struct { x: f32, y: f32, u: f32, v: f32 };

/// Twice the signed area of the triangle abp. Positive on one side of the line
/// ab and negative on the other. The sign is the inside test.
fn edge(ax: f32, ay: f32, bx: f32, by: f32, px: f32, py: f32) f32 {
    return (bx - ax) * (py - ay) - (by - ay) * (px - ax);
}

/// Nearest-neighbour sample. `wrap` sets the meaning of a coordinate outside
/// 0..1: repeat the image, or keep the edge texel.
fn sample(tex: Texture, u: f32, v: f32, wrap: bool) u32 {
    const w: i32 = @intCast(tex.width);
    const h: i32 = @intCast(tex.height);
    var tx: i32 = @intFromFloat(@floor(u * @as(f32, @floatFromInt(w))));
    var ty: i32 = @intFromFloat(@floor(v * @as(f32, @floatFromInt(h))));

    if (wrap) {
        // Use `@mod`, not `%`. The remainder operator keeps the sign of the
        // dividend. Thus a u of -0.1 would index backwards out of the texture.
        tx = @mod(tx, w);
        ty = @mod(ty, h);
    } else {
        tx = @max(0, @min(w - 1, tx));
        ty = @max(0, @min(h - 1, ty));
    }

    return tex.pixels[@intCast(ty * w + tx)];
}

/// The same barycentric rasteriser as the triangles chapter, with one change:
/// the three weights interpolate `u` and `v`, not a colour.
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
            // Sample at the centre of the pixel. Thus a shared edge between two
            // triangles does not lose a line of pixels.
            const px = @as(f32, @floatFromInt(x)) + 0.5;
            const py = @as(f32, @floatFromInt(y)) + 0.5;

            const w0 = edge(b.x, b.y, c.x, c.y, px, py) / area;
            const w1 = edge(c.x, c.y, a.x, a.y, px, py) / area;
            const w2 = edge(a.x, a.y, b.x, b.y, px, py) / area;
            if (w0 < 0 or w1 < 0 or w2 < 0) continue;

            // The interpolation. The three weights apply to the texture
            // coordinates of the corners exactly as they apply to colours.
            const u = w0 * a.u + w1 * b.u + w2 * c.u;
            const v = w0 * a.v + w1 * b.v + w2 * c.v;
            dst.set(x, y, sample(tex, u, v, wrap));
        }
    }
}

/// Four corners and two triangles. The two triangles share the diagonal.
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

    // Left: the image one time, from corner to corner. Right: the same
    // rectangle, but the coordinates go to 2, not 1. Thus the sampler goes
    // past the edge of the texture in each direction. The wrap returns the
    // sampler to the start of the texture, and the image shows two times.
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

    // A trapezoid: the top edge is shorter than the bottom edge. Thus no one
    // affine map covers all four corners. Each triangle gets its own map, and
    // the two maps do not agree on the shared diagonal.
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

**The interpolation uses the same three weights.** The program calculates `w0`, `w1` and `w2` exactly as it did for Gouraud shading. The only change is the values that the weights multiply:

```zig
const u = w0 * a.u + w1 * b.u + w2 * c.u;
const v = w0 * a.v + w1 * b.v + w2 * c.v;
```

**The coordinates go from 0 to 1, not from 0 to 8.** The texture is a square of 8 by 8 pixels, and only `sample` refers to that size. With normalized coordinates, the same four corners address a texture of 16 pixels or of 4096 pixels. The geometry does not know which texture it has.

**A coordinate past 1 is not an error.** The square on the right asks for coordinates up to 2. Wrapping changes that range into two copies of the image in each direction. A clamp would stretch the edge texels into a smear. The two choices are both reasonable, and you must tell the sampler which one to use.

**The trapezoid has a seam.** Look along its diagonal. The program draws a shape with four corners as two triangles, and each triangle gets its own affine interpolation. When the shape is not a parallelogram, the two maps do not agree along the edge that they share.

## The seam is not a bug in the rasteriser

The seam comes from a limit of an affine map. The three corners of a triangle set a linear relation between position and texture coordinate. The three corners set this relation exactly, and no freedom remains. Four corners are one constraint too many. Thus two triangles solve two separate problems, and the two answers meet at the diagonal but do not agree.

If you draw a parallelogram, the seam does not occur. For a parallelogram, one affine map does satisfy all four corners. Thus the two triangles agree because of their construction.

The seam is the same defect as perspective in 3D. In 2D, the defect is easier to see. A wall that goes away into the distance is a trapezoid on the screen. Thus the texture coordinates change non-linearly across the wall.

Games of the mid nineties interpolated those coordinates linearly, and that caused the floors that wobbled. The fix is to interpolate the reciprocals together with the coordinates, and to divide at each pixel. The name of that fix is "perspective correct". For much of the hardware of that time, the fix cost too much.

## Why a texture is not a canvas

Here, `Texture` is a separate type, with `pixels`, `width` and `height` and no `stride`. The absence of `stride` is a deliberate difference from [the canvas](https://www.ziglang.in/learn/graphics/sub-canvas/). No code in this program samples a rectangle from the middle of a larger image. Thus the type does not need a second width.

The separate type gives a guarantee. `Texture` has no `set`, and its pixels are `[]const u32`. Thus the type shows which image the code reads and which image the code writes. If you give the destination where the source must go, the code does not compile.

The alternative is one type for the two ends. olive.c uses that alternative, and it is not wrong. With one type, you can use a rendered canvas as a texture immediately. Render-to-texture works this way, and a compositor uses a window this way. The cost is that nothing stops a write through a handle that you wanted to use only for reads.

## Check yourself

The sampler floors the scaled coordinate to select a texel. If wrapping is off, what occurs at exactly `u = 1.0`?

`u * 8` is `8`, the floor of 8 is `8`, and the last valid index of the texture is `7`. The clamp catches this value and returns texel 7. For that reason, the branch reads `@min(w - 1, tx)`, not `@min(w, tx)`.

In this program, no pixel gets to that value. `u` is exactly 1 only on the line through the other two corners, where the weight of the `u = 0` corner becomes 0. For the left square, that line is `x = 26`. The centres of the pixels are at half-integers. Thus each pixel centre is half a pixel away from that line.

Thus the picture above never tests the guard, and nothing here would show an error in the guard. Also, the snippet on this page ships without the bounds check. Suppose that the guard is wrong, and you move one vertex to a half-integer. Then the read goes past the end of the texture. A safety build catches that read with a panic. This build returns a pixel from the memory after the texture.

## If you know C

The rasteriser has the shape that you would write in C, with one difference: it uses `@mod`, not `%`.

In C, `%` keeps the sign of the dividend. Thus `-1 % 8` is `-1`, and a texture coordinate that becomes slightly negative indexes backwards out of the array. The symptom is one wrong row or column along one edge. You can easily think that this symptom is an off-by-one error in the geometry.

Zig does not let you write that error by accident. The reason is not that Zig selects the other answer. `%` on signed integers is a compile error:

```
error: remainder division with 'i32' and 'i32': signed integers
and floats must use @rem or @mod
```

`@rem(-1, 8)` is `-1`, the same as C. `@mod(-1, 8)` is `7`, because it takes the sign of the divisor. A sampler needs this wrapping. Zig has the two functions, and neither one is the default. Thus you must select one.

Next: move the shape, not the pixels inside the shape.
