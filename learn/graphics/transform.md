# Transforms

> To move, turn and resize a shape is one operation. To combine them is a multiply, and you cannot select its order freely.

[The scene graph](https://www.ziglang.in/learn/graphics/scene/) stored two integers for each node, and that chapter gave the limit: two integers only let a node move. A full scene graph stores a matrix. Thus a node can also turn and change its size. To combine a parent with a child, the walk then multiplies two matrices. This chapter builds that matrix.

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
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`09-graphics.transform`)*

## What just happened

**Six numbers cover all cases.** A move, a turn, a scale and a shear are four ways to fill the same six slots. A routine that applies a transform does not know which of the four it got.

**The order changes the answer.** The two arrows in the first picture come from the same quarter turn and the same offset, combined in the two possible orders. The rotation is about the origin. Thus, if the move occurs first, the turn also turns the offset. The shape goes a quarter circle to a different position. The picture shows that matrix multiplication is not commutative.

**A turn about a point is three transforms.** No `rotate` function takes a centre. Do these three steps:

1. Move the pivot to the origin.
2. Turn.
3. Move the pivot back.

The three steps combine into one matrix, and that matrix costs the same as one rotation. The arrows with the numbers 1, 2 and 3 move around the `+`, but the program has no code for an orbit. Each arrow is this matrix with a different angle.

**The program never changes the shape.** `shape` is one `const` array of seven points. The program draws it eight times in the three pictures. Each difference is in the matrix.

## Read a composition

In practice, transforms are difficult because the usual notation is in the reverse order of the operations. With matrices, to apply `A` and then `B` to a column vector, you write `B * A * p`. The matrix nearest the point acts first. Thus you read the chain from right to left.

`then` hides that reverse order. `a.then(b)` means `a` first, and the function calculates `b * a` internally. The reversal occurs one time, in one function. A person who reads the call does not have to reverse the order mentally:

```zig
const about_pivot = Transform.translate(-pivot_x, -pivot_y)
    .then(Transform.rotate(quarter_turn * steps))
    .then(Transform.translate(pivot_x, pivot_y));
```

The code gives the three operations in the order that they occur. The code builds the same matrix that a graphics textbook writes as `T * R * T⁻¹`.

The program combines the aspect ratio of the display in the same way. A character cell is approximately two times as tall as it is wide. Thus each point gets a final non-uniform scale of `(2, 1)`.

The transforms above do not include this scale. Thus a rotation in this program keeps the angles of the shape correct. The program calculates the shape in square units. At the end, one matrix squashes the shape, and that matrix is the same as all the other matrices.

## The purpose of the bottom row

The matrix is 3x3, but the program stores only six numbers. The row that the program does not store is always `0 0 1`. Thus the program does not need to store it.

The row exists because translation is not a linear operation. A 2x2 matrix multiply can rotate, scale and shear, and each of those operations keeps the origin at the same position. A matrix made only from `a`, `b`, `c` and `d` cannot move a point away from the origin. A third coordinate, always 1, gives translation a column. The last column is that column. The multiply multiplies its entries by the 1 and adds them, and a move does exactly that.

This extra coordinate is the meaning of homogeneous coordinates. With the extra coordinate, translation becomes a multiply, the same as the other operations. Thus a chain of moves, turns and scales becomes one matrix. The program multiplies each point by that one matrix. The point does not go through each step of the chain.

Perspective goes one step more. Put values other than 0 and 1 in the bottom row, and divide by the third coordinate after the multiply. The division makes the far end of a wall smaller. The trapezoid in [texture mapping](https://www.ziglang.in/learn/graphics/texture/) did not have this division.

## Check yourself

`then` multiplies to build a new matrix. Why not apply each transform to the points, one after the other?

For seven points, the result is the same. The reason applies to seven thousand points, or to a long chain. A composition costs one multiply for each *transform*. An application costs one multiply for each *point*.

If you combine the chain first, each point pays for only one matrix, for any number of operations in the chain. For the same reason, the scene graph adds the offsets as it goes down the tree. It does not walk again from the root for each node.

The second reason is accuracy. Each application rounds. Thus five transforms, applied one after the other, round five times for each point. A composition rounds while it builds the matrix, and the program transforms each point one time.

## If you know C

The struct is the six-float affine matrix from all the 2D graphics APIs that you know. Examples are the matrices of Cairo and Direct2D, the six arguments to the web canvas `setTransform`, and the `AffineTransform` of Java. The order and the names of the fields are different, but the six numbers are the same.

The Zig version has two differences. First, the trigonometry uses builtins, not libc calls. Thus this snippet has no dependency to link, and the snippet runs in a browser without changes. The program above runs on this page in that way.

Second, the default field values in the struct declaration are important. `identity` is `.{}`, and each constructor sets only the fields that it needs. `translate` writes `e` and `f`, and the other four fields keep the `1, 0, 0, 1` of the identity. In C, each constructor needs four more assignments. If you forget one, you get a common bug: a translate that sets the scale to zero and gives no error.

Next: the same buffer, but the program gives it to a display server, not to a file.
