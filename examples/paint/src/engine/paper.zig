//! Paper texture: a fixed grid of heights under the whole document.
//!
//! Real paper has a surface of tiny hills and dips. A dry brush touches only
//! the tops of the hills, which is what gives a dry-brush stroke its broken,
//! grainy look. The grain belongs to the paper, not to the stroke, so two
//! strokes across the same spot skip the same dips.
//!
//! So the heights are made once, from a seed, and stored per cell in document
//! coordinates. They never move with the brush.

const std = @import("std");
const Random = @import("random.zig").Random;

pub const Paper = struct {
    /// Width and height of one cell, in pixels.
    cell: u32,
    columns: u32,
    rows: u32,
    /// One height per cell, row by row: 0 is the bottom of a dip, 255 the
    /// top of a hill.
    heights: []u8,

    pub fn init(gpa: std.mem.Allocator, width: u32, height: u32, cell: u32, seed: u32) !Paper {
        const columns = (width + cell - 1) / cell;
        const rows = (height + cell - 1) / cell;
        const heights = try gpa.alloc(u8, @as(usize, columns) * rows);
        var random: Random = .init(seed);
        for (heights) |*h| h.* = @intFromFloat(@round(random.next() * 255.0));
        return .{ .cell = cell, .columns = columns, .rows = rows, .heights = heights };
    }

    pub fn deinit(p: *Paper, gpa: std.mem.Allocator) void {
        gpa.free(p.heights);
    }

    /// The height under pixel (`x`, `y`). Every pixel in a cell shares one
    /// height, so the grain is `cell` pixels across.
    pub fn at(p: Paper, x: u32, y: u32) u8 {
        const column = @min(x / p.cell, p.columns - 1);
        const row = @min(y / p.cell, p.rows - 1);
        return p.heights[@as(usize, row) * p.columns + column];
    }

    /// Whether a brush with this `contact` (0 to 1) reaches the paper at
    /// (`x`, `y`). Full contact reaches every height. Less contact reaches
    /// only the hills: at 0.3, only heights in the top 30%.
    pub fn touches(p: Paper, x: u32, y: u32, contact: f32) bool {
        const threshold = (1.0 - contact) * 255.0;
        return @as(f32, @floatFromInt(p.at(x, y))) >= threshold;
    }
};

test "the cell under a pixel: (22, 10) with cells of 4 is column 5, row 2" {
    var p = try Paper.init(std.testing.allocator, 640, 400, 4, 1);
    defer p.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 160), p.columns);
    try std.testing.expectEqual(p.heights[2 * 160 + 5], p.at(22, 10));
    try std.testing.expectEqual(p.at(20, 8), p.at(23, 11)); // same cell
}

test "the same seed makes the same paper" {
    var a = try Paper.init(std.testing.allocator, 64, 64, 4, 9);
    defer a.deinit(std.testing.allocator);
    var b = try Paper.init(std.testing.allocator, 64, 64, 4, 9);
    defer b.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, a.heights, b.heights);
}

test "contact: 30% reaches a high cell but not a low one, 100% reaches both" {
    var heights = [_]u8{ 204, 102 }; // 0.8 and 0.4 of the way up
    const p: Paper = .{ .cell = 1, .columns = 2, .rows = 1, .heights = &heights };
    try std.testing.expect(p.touches(0, 0, 0.3));
    try std.testing.expect(!p.touches(1, 0, 0.3));
    try std.testing.expect(p.touches(0, 0, 1));
    try std.testing.expect(p.touches(1, 0, 1));
}
