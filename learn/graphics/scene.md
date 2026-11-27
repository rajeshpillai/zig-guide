# A Scene Graph

> Position each thing relative to its parent. When the parent moves, everything below the parent moves with it.

To draw one sprite, you must know where the sprite goes. To draw fifty sprites that belong together, you must know where all fifty go. When the group moves, all fifty numbers must stay correct. A scene graph solves this problem.

Do not store where each thing is. Store where each thing is **relative to its parent**, and calculate the rest. An arm is always at "shoulder plus two", and the shoulder can go to any position.

## The program

```zig
const std = @import("std");

const width: usize = 44;
const height: usize = 12;
var canvas: [width * height]u8 = @splat('.');

/// The position of a node is **local**: it is relative to its parent, not to
/// the canvas. An arm is always at "shoulder plus two", and the shoulder can
/// move to any position.
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

/// Walk the tree and add up the offsets. Each node draws at the position of
/// its parent plus its own offset. Then the node gives that total to its
/// children. The walk adds one time for each level, and that addition is the
/// transform.
///
/// A real engine stores a 3x3 matrix, not two integers. Thus a node can also
/// rotate and scale. To combine the values, the walk multiplies matrices. It
/// does not add numbers. The structure of the walk is the same.
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

    // Index 0 is the body. The other nodes are children of the body, and
    // their positions are relative to the body. Only index 0 refers to the
    // canvas.
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

    // Two numbers change. Each child follows the body, because no child
    // stores its position on the canvas.
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

**Two lines changed and four shapes moved.** `nodes[0]` went from (4, 3) to (26, 5). The program did not change other items in the array. The head and the two arms followed the body, because no child knew its position on the canvas.

**The transform is an addition.** Each node draws at the position of its parent plus its own offset. Then the node gives that total to its children. The walk adds one time for each level, and the total grows as the walk goes down the tree.

The layout engine uses the same downward walk for the same reason. The position of a child depends on its parent. The position of a parent does not depend on its child.

**The order in the array is not the order in the tree.** The program stores the nodes in a flat array and links them by index. The order of the siblings sets the order of the paint. This is the painter's algorithm again: a later sibling covers an earlier sibling.

## What a real scene graph stores

Two integers only let a node move. A full scene graph stores a **matrix** for each node, usually 3x3 for 2D. With a matrix, a node can also rotate and scale. To combine a parent with a child, the walk multiplies two matrices. It does not add two numbers.

The matrices give scene graphs their main benefit. A rotation on the parent turns each child around the *origin of the parent*, and no child knows about the rotation. When a robot turns its shoulder, the full arm moves. No part of the arm refers to the rotation.

The structure of the walk does not change. Add the parent value to each node, draw the node, and then do the same steps for each child.

## Check yourself

The walk calculates each position again on each frame. Is that a waste of time?

Usually it is not, and a cache has its own cost. If you keep a cache of the world position of each node, a parent that moves makes the cache incorrect for its full subtree. In an animated scene, most parents move on most frames. Thus the program must clear the cache approximately as frequently as it reads the cache.

Usually, an engine that keeps this cache solves a different problem. The engine needs the world position for a task other than the drawing, for example hit tests or physics. Without the cache, each query must walk from the root. The cache is a good choice when the reads are more frequent than the writes. The same question applies to [an index in a database](https://www.ziglang.in/learn/storage/indexes/).

## If you know C

The tree is `struct Node { int x, y; struct Node *first, *next; }` and the walk is the same recursion. Two known risks apply.

Deep recursion on a scene with deep nesting overflows the stack. A scene graph that a program loads from a file can have any depth. If the file is malformed, the graph can also have a cycle. A production loader checks the depth and rejects cycles. Another solution is to write the walk again with an explicit stack.

The flat array in this program has the usual advantage over pointers:

- The full scene is one allocation.
- One call frees the scene.
- The walk reads contiguous memory.

Contiguous memory makes the walk faster. This is important when the walk occurs sixty times each second.

Next: a chart. A chart is a scene where the positions come from data.
