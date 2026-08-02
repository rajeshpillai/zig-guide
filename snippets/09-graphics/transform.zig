//! title: Transforms
//! Moving, turning and resizing are one operation, and composing them is a multiply whose order you do not get to choose freely.

const std = @import("std");

const width: usize = 58;
const height: usize = 17;

var framebuffer: [width * height]u8 = undefined;

/// A 2D affine transform: the top two rows of a 3x3 matrix.
///
///     | a c e |     x' = a*x + c*y + e
///     | b d f |     y' = b*x + d*y + f
///     | 0 0 1 |
///
/// The bottom row is always `0 0 1` for an affine transform, so storing it
/// would be storing a constant. Six numbers hold every combination of moving,
/// turning, scaling and shearing there is.
const Transform = struct {
    a: f32 = 1,
    b: f32 = 0,
    c: f32 = 0,
    d: f32 = 1,
    e: f32 = 0,
    f: f32 = 0,

    const identity: Transform = .{};

    fn translate(dx: f32, dy: f32) Transform {
        return .{ .e = dx, .f = dy };
    }

    fn scale(sx: f32, sy: f32) Transform {
        return .{ .a = sx, .d = sy };
    }

    fn rotate(radians: f32) Transform {
        const cos = @cos(radians);
        const sin = @sin(radians);
        return .{ .a = cos, .b = sin, .c = -sin, .d = cos };
    }

    /// `self.then(next)` is the transform that applies `self` first. Written
    /// as matrices that is `next * self`, because a point is a column on the
    /// right and the matrix nearest it acts first. Reading a chain left to
    /// right in the order things happen is the reason for the name.
    fn then(self: Transform, next: Transform) Transform {
        return .{
            .a = next.a * self.a + next.c * self.b,
            .b = next.b * self.a + next.d * self.b,
            .c = next.a * self.c + next.c * self.d,
            .d = next.b * self.c + next.d * self.d,
            .e = next.a * self.e + next.c * self.f + next.e,
            .f = next.b * self.e + next.d * self.f + next.f,
        };
    }

    fn apply(self: Transform, x: f32, y: f32) struct { x: f32, y: f32 } {
        return .{
            .x = self.a * x + self.c * y + self.e,
            .y = self.b * x + self.d * y + self.f,
        };
    }
};

/// The shape, in its own coordinates. An arrow, because it has no symmetry:
/// a rotated square looks like a square, which proves nothing.
const shape = [_][2]f32{
    .{ 0, -3 },
    .{ 2, 0 },
    .{ 1, 0 },
    .{ 1, 3 },
    .{ -1, 3 },
    .{ -1, 0 },
    .{ -2, 0 },
};

fn clear() void {
    @memset(&framebuffer, ' ');
}

fn plot(x: i32, y: i32, ink: u8) void {
    if (x < 0 or y < 0) return;
    const ux: usize = @intCast(x);
    const uy: usize = @intCast(y);
    if (ux >= width or uy >= height) return;
    framebuffer[uy * width + ux] = ink;
}

/// Bresenham, so an edge of the shape is drawn rather than sampled.
fn line(x0: i32, y0: i32, x1: i32, y1: i32, ink: u8) void {
    var x = x0;
    var y = y0;
    const dx: i32 = @intCast(@abs(x1 - x0));
    const dy: i32 = -@as(i32, @intCast(@abs(y1 - y0)));
    const sx: i32 = if (x0 < x1) 1 else -1;
    const sy: i32 = if (y0 < y1) 1 else -1;
    var err = dx + dy;

    while (true) {
        plot(x, y, ink);
        if (x == x1 and y == y1) break;
        const e2 = 2 * err;
        if (e2 >= dy) {
            err += dy;
            x += sx;
        }
        if (e2 <= dx) {
            err += dx;
            y += sy;
        }
    }
}

/// A character cell is about twice as tall as it is wide, so the last thing
/// done to every point is a non-uniform scale that undoes it. Composing it here
/// rather than multiplying by two at the call site is the practical reason to
/// have `then` at all: the transforms above stay in square units, where a
/// rotation is a rotation, and the display's odd aspect is one matrix applied
/// after everything else.
const aspect = Transform.scale(2, 1);

/// Transform every point, then draw the outline through the results. The shape
/// itself is never modified: it is one array, drawn through different matrices.
fn draw(t: Transform, ink: u8) void {
    const view = t.then(aspect);
    for (shape, 0..) |point, i| {
        const next = shape[(i + 1) % shape.len];
        const p = view.apply(point[0], point[1]);
        const q = view.apply(next[0], next[1]);
        line(
            @intFromFloat(@round(p.x)),
            @intFromFloat(@round(p.y)),
            @intFromFloat(@round(q.x)),
            @intFromFloat(@round(q.y)),
            ink,
        );
    }
}

fn dump(out: *std.Io.Writer) !void {
    for (0..height) |y| {
        const row = framebuffer[y * width ..][0..width];
        try out.writeAll(std.mem.trimEnd(u8, row, " "));
        try out.writeByte('\n');
    }
}

const quarter_turn: f32 = std.math.pi / 2.0;

pub fn main(init: std.process.Init) !void {
    var buf: [8192]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    // Rotate then move, against move then rotate. Same quarter turn, same
    // offset, composed in the two possible orders. Both are then shifted by the
    // same amount so each lands on the canvas, which changes where the pair
    // sits but not how far apart they are.
    const view = Transform.translate(13, 6);
    const spin_then_move = Transform.rotate(quarter_turn)
        .then(Transform.translate(7, 0))
        .then(view);
    const move_then_spin = Transform.translate(7, 0)
        .then(Transform.rotate(quarter_turn))
        .then(view);

    clear();
    draw(spin_then_move, '#');
    draw(move_then_spin, 'o');
    try out.writeAll("# rotate then move, o move then rotate\n");
    try dump(out);

    // Turning a shape about a point that is not the origin is three transforms:
    // bring the point to the origin, turn, put it back. There is no rotate
    // that takes a centre, and this is the reason none is needed.
    const pivot_x: f32 = 16;
    const pivot_y: f32 = 7;
    clear();
    for ([_]f32{ 0, 1, 2 }, "123") |steps, ink| {
        const about_pivot = Transform.translate(-pivot_x, -pivot_y)
            .then(Transform.rotate(quarter_turn * steps))
            .then(Transform.translate(pivot_x, pivot_y));
        // Placed five units to the right of the pivot, then turned about it,
        // so the arrow orbits rather than spinning where it stands.
        draw(Transform.translate(pivot_x + 5, pivot_y).then(about_pivot), ink);
    }
    plot(@intFromFloat(pivot_x * 2), @intFromFloat(pivot_y), '+');
    try out.writeAll("\n+ is the pivot; 1, 2 and 3 are quarter turns about it\n");
    try dump(out);

    // Scale lives in the same six numbers and composes the same way.
    clear();
    draw(Transform.scale(1, 1).then(Transform.translate(5, 8)), '.');
    draw(Transform.scale(1.6, 1.6).then(Transform.translate(13, 8)), '+');
    draw(Transform.scale(2.2, 2.2).then(Transform.translate(23, 8)), '#');
    try out.writeAll("\nthe same seven points at three scales\n");
    try dump(out);

    try out.flush();
}
