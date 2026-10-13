//! Flood fill: every pixel connected to a starting pixel by the same colour.
//!
//! The region is found a little at a time. Each pixel we accept can reveal
//! more neighbours, so we keep a queue of pixels still to look at and a map of
//! pixels already seen.
//!
//! A recursive version, "fill this pixel, then fill its four neighbours", is
//! shorter and wrong for a paint program. A 640 by 400 region would nest
//! 256,000 calls deep and run out of stack long before it finished.
//!
//! Matching is exact and uses four neighbours: left, right, up and down. So a
//! fill stops at a diagonal gap, and it leaves the soft, partly covered edge
//! of a brush stroke unfilled, as a thin fringe.

const std = @import("std");
const Rect = @import("geometry.zig").Rect;
const Rgba = @import("pixel.zig").Rgba;

pub const Region = struct {
    /// One bit per pixel of the image: set means "in the region".
    inside: std.bit_set.Dynamic,
    /// The smallest rectangle holding the region.
    bounds: Rect,
    count: usize,

    pub fn deinit(r: *Region, gpa: std.mem.Allocator) void {
        r.inside.deinit(gpa);
    }
};

/// Find the region of `pixels` connected to (`x`, `y`) that has exactly the
/// colour at (`x`, `y`).
pub fn find(
    gpa: std.mem.Allocator,
    pixels: []const Rgba,
    width: u32,
    height: u32,
    x: u32,
    y: u32,
) !Region {
    const total = @as(usize, width) * height;
    var inside: std.bit_set.Dynamic = try .initEmpty(gpa, total);
    errdefer inside.deinit(gpa);

    // Every pixel enters the queue at most once, because it is marked when it
    // goes in rather than when it comes out. So the queue never needs more
    // room than the image has pixels, and a plain array with a read position
    // is enough: nothing is ever moved.
    const queue = try gpa.alloc(u32, total);
    defer gpa.free(queue);
    var head: usize = 0;
    var tail: usize = 0;

    const target = pixels[@as(usize, y) * width + x];
    const start: u32 = y * width + x;
    inside.set(start);
    queue[tail] = start;
    tail += 1;

    var bounds: Rect = .{ .x0 = x, .y0 = y, .x1 = x + 1, .y1 = y + 1 };
    while (head < tail) {
        const i = queue[head];
        head += 1;
        const px = i % width;
        const py = i / width;
        bounds = bounds.join(.{ .x0 = px, .y0 = py, .x1 = px + 1, .y1 = py + 1 });

        // The four neighbours, skipping any that would fall off an edge.
        const neighbours = [4]?u32{
            if (px > 0) i - 1 else null,
            if (px + 1 < width) i + 1 else null,
            if (py > 0) i - width else null,
            if (py + 1 < height) i + width else null,
        };
        for (neighbours) |maybe| {
            const n = maybe orelse continue;
            if (inside.isSet(n)) continue;
            if (!std.meta.eql(pixels[n], target)) continue;
            inside.set(n);
            queue[tail] = n;
            tail += 1;
        }
    }
    return .{ .inside = inside, .bounds = bounds, .count = tail };
}

const testing = std.testing;

/// A test picture drawn with characters: `#` is black, `.` is transparent.
fn picture(comptime rows: []const []const u8) [rows.len * rows[0].len]Rgba {
    var out: [rows.len * rows[0].len]Rgba = undefined;
    for (rows, 0..) |row, y| for (row, 0..) |c, x| {
        out[y * rows[0].len + x] = if (c == '#') .opaqueRgb(.{ 0, 0, 0 }) else .transparent;
    };
    return out;
}

test "a closed shape fills inside and stops at its walls" {
    const p = picture(&.{
        "#######",
        "#.....#",
        "#.###.#",
        "#.#.#.#",
        "#######",
    });
    var r = try find(testing.allocator, &p, 7, 5, 1, 1);
    defer r.deinit(testing.allocator);
    // The 9 dots around the inner box (5 + 2 + 2), not the one inside it.
    try testing.expectEqual(@as(usize, 9), r.count);
    try testing.expect(!r.inside.isSet(3 * 7 + 3));
    try testing.expectEqual(Rect{ .x0 = 1, .y0 = 1, .x1 = 6, .y1 = 4 }, r.bounds);
}

test "four neighbours do not leak through a diagonal gap" {
    const p = picture(&.{
        ".#",
        "#.",
    });
    var r = try find(testing.allocator, &p, 2, 2, 0, 0);
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), r.count);
}

test "a whole empty 640 by 400 image fills without recursion" {
    const gpa = testing.allocator;
    const p = try gpa.alloc(Rgba, 640 * 400);
    defer gpa.free(p);
    @memset(p, .transparent);
    var r = try find(gpa, p, 640, 400, 320, 200);
    defer r.deinit(gpa);
    try testing.expectEqual(@as(usize, 640 * 400), r.count);
    try testing.expectEqual(Rect{ .x0 = 0, .y0 = 0, .x1 = 640, .y1 = 400 }, r.bounds);
}

test "no leak when an allocation fails" {
    const p = picture(&.{ "...", "..." });
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(gpa: std.mem.Allocator, pixels: []const Rgba) !void {
            var r = try find(gpa, pixels, 3, 2, 0, 0);
            r.deinit(gpa);
        }
    }.run, .{@as([]const Rgba, &p)});
}
