//! title: A Scene Graph
//! Position a thing once, relative to its parent, and moving the parent moves everything.

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
