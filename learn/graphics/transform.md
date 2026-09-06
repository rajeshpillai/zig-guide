# Transforms

> Moving, turning and resizing are one operation, and composing them is a multiply whose order you do not get to choose freely.

[The scene graph](https://www.ziglang.in/learn/graphics/scene/) stored two integers per node and
admitted the limit in passing: two integers only let a node move. A real one
carries a matrix, so a node can turn and resize as well, and composing a
parent with a child becomes a multiply. This is that matrix.

## The program

```zig
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
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`09-graphics.transform`)*

## What just happened

**Six numbers cover every case.** Moving, turning, scaling and shearing are not
four features. They are four ways of filling in the same six slots, and a
routine that applies a transform does not know which of them it was handed.

**Order changes the answer.** The two arrows in the first picture come from the
same quarter turn and the same offset, composed both ways round. Rotation is
about the origin, so moving first means turning the offset too, and the shape
travels a quarter circle to somewhere else entirely. Matrix multiplication is
not commutative, and this is what that sentence looks like.

**Turning about a point is three transforms.** There is no `rotate` that takes
a centre. Move the pivot to the origin, turn, move it back, and the
composition of those three is a single matrix costing exactly what one
rotation costs. The arrows numbered 1, 2 and 3 orbit the `+` without any of
them containing an orbit.

**The shape is never modified.** `shape` is one array of seven points, `const`,
drawn eleven times across the three pictures. Every difference is in the
matrix.

## Reading a composition

The awkward part of transforms in practice is that the conventional way to
write them runs backwards from the order things happen. As matrices, applying
`A` and then `B` to a column vector is `B * A * p`: the one nearest the point
acts first, so the chain reads right to left.

`then` exists to hide that. `a.then(b)` means `a` first, and internally it
computes `b * a`. The reversal happens once, in one function, rather than in
the head of everyone reading the call:

```zig
const about_pivot = Transform.translate(-pivot_x, -pivot_y)
    .then(Transform.rotate(quarter_turn * steps))
    .then(Transform.translate(pivot_x, pivot_y));
```

That is three operations in the order they occur, and it is the same matrix a
graphics text would write as `T * R * T⁻¹`.

The display's aspect ratio is composed the same way. A character cell is about
twice as tall as it is wide, so every point gets a final non-uniform scale of
`(2, 1)`. Keeping it out of the transforms above is why a rotation in this
program is a rotation. The shape is reasoned about in square units and
squashed once, at the end, by a matrix like any other.

## What the bottom row is for

The matrix is 3x3 but only six numbers are stored. The missing row is always
`0 0 1`, and storing a constant would be storing a constant.

It exists because translation is not a linear operation. A 2x2 matrix multiply
can rotate, scale and shear, and every one of those leaves the origin where it
is. Nothing built from `a`, `b`, `c` and `d` alone can move a point away from
the origin. Adding a third coordinate fixed at 1 gives translation a column to
live in. The last column is that column: its entries are multiplied by the 1
and added, which is exactly what a move does.

That is the whole trick behind homogeneous coordinates. The payoff is not
elegance. It is that translation joins the others as a multiply, so a chain of
moves, turns and scales collapses into one matrix, applied once per point
instead of a pipeline walked per point.

Perspective is the same idea taken one step further. Let the bottom row hold
something other than 0 and 1, divide by the third coordinate afterwards, and
the division is where the far end of a wall gets smaller. That division is
also exactly what the trapezoid in [texture mapping](https://www.ziglang.in/learn/graphics/texture/)
was missing.

## Check yourself

`then` builds a new matrix by multiplying. Why not skip it and apply each
transform to the points in turn?

For seven points it makes no difference. The reason is what happens when there
are seven thousand, or when the chain is deep: composing costs one multiply
per
*transform*, applying costs one per *point*. Fold the chain first and every point pays for one matrix, regardless of how
many operations went into it. That is the same reason the scene graph
accumulates an offset on the way down the tree, instead of re-walking from the
root at every node.

The second reason is accuracy. Each application rounds, so applying five
transforms in turn rounds five times per point. Composing rounds once while
building the matrix, and the points are transformed once.

## If you have written C

The struct is the six-float affine matrix from every 2D graphics API you have
met. Cairo's, Direct2D's, the six arguments to the web canvas `setTransform`,
and Java's `AffineTransform`. Field order and naming differ, and it is always
these six.

Two differences in the Zig. The trigonometry is builtins rather than libc
calls, so this snippet has no dependency to link and runs unchanged in a
browser. That is why the program above is running in this page.

And the default field values in the struct declaration are doing real work.
`identity` is `.{}`, and each constructor sets only the fields it cares about:
`translate` writes `e` and `f` and the other four come back as the identity's
`1, 0, 0, 1`. In C those are four more assignments per constructor, and
forgetting one is the classic bug where a translate quietly zeroes the scale.

Next: the same buffer, handed to a display server rather than to a file.
