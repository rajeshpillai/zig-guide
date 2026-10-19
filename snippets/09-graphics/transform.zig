//! title: Transforms
//! To move, turn and resize a shape is one operation. To combine them is a multiply, and you cannot select its order freely.

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
/// For an affine transform, the bottom row is always `0 0 1`. Thus the struct
/// does not store the bottom row, because it is a constant. Six numbers hold
/// each possible combination of move, turn, scale and shear.
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

    /// `self.then(next)` is the transform that applies `self` first. As
    /// matrices, the transform is `next * self`, because a point is a column
    /// on the right, and the matrix nearest the point acts first. With `then`,
    /// you read a chain from left to right, in the order of the operations.
    /// That is the reason for the name.
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

/// The shape, in its own coordinates. The shape is an arrow because an arrow
/// has no symmetry. A rotated square looks like a square, and thus shows
/// nothing.
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

/// Bresenham. Thus the program draws each edge of the shape as a line. It
/// does not sample the edge.
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

/// A character cell is approximately two times as tall as it is wide. Thus
/// the last operation on each point is a non-uniform scale that cancels that
/// difference. The program combines the scale here with `then`. It does not
/// multiply by two at the call site, and that is the main reason for `then`.
/// The transforms above stay in square units, where a rotation keeps the
/// shape. The uneven aspect of the display is one matrix, and the program
/// applies it after all the other matrices.
const aspect = Transform.scale(2, 1);

/// Transform each point, then draw the outline through the results. The
/// program never changes the shape. The shape is one array, and the program
/// draws it through different matrices.
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

    // Rotate then move, compared with move then rotate. The same quarter turn
    // and the same offset, combined in the two possible orders. Then the
    // program moves the two shapes by the same distance to put them on the
    // canvas. This move changes the position of the pair, but not the
    // distance between the two shapes.
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

    // Three transforms turn a shape about a point that is not the origin.
    // Move the point to the origin, turn, and move the point back.
    // No rotate function takes a centre, because these three steps do the
    // same work.
    const pivot_x: f32 = 16;
    const pivot_y: f32 = 7;
    clear();
    for ([_]f32{ 0, 1, 2 }, "123") |steps, ink| {
        const about_pivot = Transform.translate(-pivot_x, -pivot_y)
            .then(Transform.rotate(quarter_turn * steps))
            .then(Transform.translate(pivot_x, pivot_y));
        // Put the arrow five units to the right of the pivot, then turn the
        // arrow about the pivot. Thus the arrow moves in an orbit. The arrow
        // does not turn at its own position.
        draw(Transform.translate(pivot_x + 5, pivot_y).then(about_pivot), ink);
    }
    plot(@intFromFloat(pivot_x * 2), @intFromFloat(pivot_y), '+');
    try out.writeAll("\n+ is the pivot; 1, 2 and 3 are quarter turns about it\n");
    try dump(out);

    // A scale uses the same six numbers, and it combines in the same way.
    clear();
    draw(Transform.scale(1, 1).then(Transform.translate(5, 8)), '.');
    draw(Transform.scale(1.6, 1.6).then(Transform.translate(13, 8)), '+');
    draw(Transform.scale(2.2, 2.2).then(Transform.translate(23, 8)), '#');
    try out.writeAll("\nthe same seven points at three scales\n");
    try dump(out);

    try out.flush();
}
