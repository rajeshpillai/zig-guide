//! title: Texture Mapping
//! The triangle already interpolates. Point the triangle at a second image, and it interpolates coordinates into that image, not colours.

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
