# A Scene Graph

> Position a thing once, relative to its parent, and moving the parent moves everything.

Drawing one sprite means knowing where it goes. Drawing fifty that belong
together means knowing where all of them go, and keeping those fifty numbers
correct as the group moves is the problem a scene graph solves.

The idea is to stop storing where things are. Store where each thing is
**relative to its parent**, and compute the rest. An arm is at "shoulder plus
two", permanently, and the shoulder is free to go anywhere.

## The program

```zig
const std = @import("std");

const width: usize = 44;
const height: usize = 12;
var canvas: [width * height]u8 = @splat('.');

/// A node's position is **local**: relative to its parent, not to the canvas.
/// That is the whole idea. An arm is at "shoulder plus two", forever, and the
/// shoulder is free to move.
const Node = struct {
    x: i32,
    y: i32,
    w: i32 = 1,
    h: i32 = 1,
    ink: u8 = '#',
    first: ?u32 = null,
    next: ?u32 = null,
};

fn fill(x: i32, y: i32, w: i32, h: i32, ink: u8) void {
    var row: i32 = 0;
    while (row < h) : (row += 1) {
        var col: i32 = 0;
        while (col < w) : (col += 1) {
            const px = x + col;
            const py = y + row;
            if (px < 0 or py < 0) continue;
            const ux: usize = @intCast(px);
            const uy: usize = @intCast(py);
            if (ux >= width or uy >= height) continue;
            canvas[uy * width + ux] = ink;
        }
    }
}

/// Walk the tree accumulating the offset. Each node draws at parent plus its
/// own, then hands that total to its children. One addition per level, and
/// that addition is the transform.
///
/// A real engine carries a 3x3 matrix instead of two integers, so a node can
/// rotate and scale as well as move, and the accumulation is a matrix multiply
/// rather than an add. The structure of the walk is identical.
fn draw(nodes: []const Node, index: u32, ox: i32, oy: i32) void {
    const node = nodes[index];
    const x = ox + node.x;
    const y = oy + node.y;
    fill(x, y, node.w, node.h, node.ink);

    var child = node.first;
    while (child) |c| : (child = nodes[c].next) draw(nodes, c, x, y);
}

fn clear() void {
    @memset(&canvas, '.');
}

fn dump(out: *std.Io.Writer) !void {
    for (0..height) |y| try out.print("{s}\n", .{canvas[y * width ..][0..width]});
}

pub fn main(init: std.process.Init) !void {
    var buf: [4096]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    // index 0 is the body; the rest hang off it and are positioned relative
    // to it. Nothing below index 0 mentions the canvas.
    var nodes = [_]Node{
        .{ .x = 4, .y = 3, .w = 6, .h = 4, .ink = '#', .first = 1 }, // body
        .{ .x = -3, .y = 1, .w = 3, .h = 1, .ink = '=', .next = 2 }, // left arm
        .{ .x = 6, .y = 1, .w = 3, .h = 1, .ink = '=', .next = 3 }, // right arm
        .{ .x = 1, .y = -2, .w = 4, .h = 2, .ink = 'o', .next = null }, // head
    };

    clear();
    draw(&nodes, 0, 0, 0);
    try out.writeAll("body at (4, 3)\n");
    try dump(out);

    // One number changed. Every child follows, because no child knows where
    // it is on the canvas and none of them had to be told.
    nodes[0].x = 26;
    nodes[0].y = 5;

    clear();
    draw(&nodes, 0, 0, 0);
    try out.writeAll("\nbody moved to (26, 5), and only that line changed\n");
    try dump(out);

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`09-graphics.scene`)*

## What just happened

**One line changed and four shapes moved.** `nodes[0].x` went from 4 to 26.
Nothing else in the array was touched, and the head and both arms followed,
because none of them ever knew where they were on the canvas.

**The transform is an addition.** Each node draws at parent plus its own
offset, and passes that total down. One add per level, accumulated on the way
down the tree. That is the same downward walk as the layout engine, and for
the same reason: a child's position depends on its parent and not the reverse.

**Order in the array is not order in the tree.** The nodes are stored flat and
linked by index. Sibling order decides painting order, which is the painter's
algorithm again: later siblings cover earlier ones.

## What a real one carries

Two integers only allow moving. A real scene graph stores a **matrix** per
node, usually 3x3 for 2D, so a node can rotate and scale too, and composing
parent with child becomes a matrix multiply rather than an add.

That change gives you the thing that makes scene graphs worth the machinery. A
rotation applied to the parent rotates every child around the *parent's*
origin, without any child knowing it happened. Rotating a robot's shoulder
sweeps the whole arm, and nothing in the arm mentions rotation.

The structure of the walk does not change at all. Accumulate down, draw at
each node, recurse.

## Check yourself

The walk recomputes every position on every frame. Is that wasteful?

Usually not, and the alternative is worse than it looks. Caching each node's
world position means invalidating the cache for an entire subtree whenever a
parent moves. In an animated scene most parents move most frames, so the cache
is invalidated about as often as it is used.

Engines that do cache it are usually solving a different problem. They need
the world position for something other than drawing, such as hit testing or
physics, where recomputing on demand would mean walking from the root for
every query. The cache is worth it when reads outnumber writes, which is the
same question as [indexing a database](https://www.ziglang.in/learn/storage/indexes/).

## If you have written C

The tree is `struct Node { int x, y; struct Node *first, *next; }` and the
walk is the same recursion. Two familiar hazards apply.

Deep recursion on a deeply nested scene overflows the stack, and a scene graph
built from a file can be arbitrarily deep, including cyclic if the file is
malformed. A production loader checks depth and rejects cycles, or the walk is
rewritten with an explicit stack.

And the flat array used here has the usual advantage over pointers: the whole
scene is one allocation, freeing it is one call, and the walk touches
contiguous memory. That last part matters more than it sounds when the walk
happens sixty times a second.

Next: a chart, which is a scene where the positions come from data.
