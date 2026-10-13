//! The stroke buffer: how much of each pixel the stroke in progress covers.
//!
//! Dabs are not drawn straight onto the layer. They build up coverage here,
//! one number per pixel, and the whole stroke is put onto the layer once, at
//! the end, with the stroke's opacity (lesson 40).
//!
//! That split is what lets a stroke at 50% opacity stay at 50% where it crosses
//! itself. Drawn straight onto the layer, every overlap of two dabs would
//! darken. Here an overlap only raises the coverage towards 1, and the opacity
//! is applied once on top of that.
//!
//! Coverage is a `u16`, so 0 is none and 65535 is full. Eight bits would not
//! do: at a flow of 2% one dab adds 5 out of 255, and the fading edge of a
//! soft tip would come out in visible steps.

const std = @import("std");
const geometry = @import("geometry.zig");
const Rect = geometry.Rect;
const Dab = @import("stroke.zig").Dab;

pub const full: u32 = 65535;

pub const Mask = struct {
    width: u32,
    height: u32,
    coverage: []u16,
    /// Every pixel outside this rectangle is 0. Keeping it means committing,
    /// clearing and redrawing touch only the part of the image the stroke
    /// reached (lesson 65).
    dirty: Rect = .empty,

    pub fn init(gpa: std.mem.Allocator, width: u32, height: u32) !Mask {
        const coverage = try gpa.alloc(u16, @as(usize, width) * height);
        @memset(coverage, 0);
        return .{ .width = width, .height = height, .coverage = coverage };
    }

    pub fn deinit(m: *Mask, gpa: std.mem.Allocator) void {
        gpa.free(m.coverage);
    }

    pub fn at(m: Mask, x: u32, y: u32) u16 {
        return m.coverage[@as(usize, y) * m.width + x];
    }

    /// Set the dirty rectangle back to 0.
    pub fn clear(m: *Mask) void {
        const r = m.dirty;
        var y = r.y0;
        while (y < r.y1) : (y += 1) {
            const row = @as(usize, y) * m.width;
            @memset(m.coverage[row + r.x0 .. row + r.x1], 0);
        }
        m.dirty = .empty;
    }

    /// Add one dab of the tip.
    ///
    /// `hardness` is the solid fraction of the radius, `aspect` squashes the
    /// tip into an ellipse, and `flow` is how much one dab adds.
    pub fn stamp(m: *Mask, dab: Dab, hardness: f32, aspect: f32, flow: f32) void {
        const r = dab.radius;
        const box = Rect.around(dab.x, dab.y, r, m.width, m.height);
        if (box.isEmpty() or flow <= 0) return;

        // The fading band at the edge. A hard tip still gets one pixel of it,
        // or its edge would be a staircase.
        const fade = @max((1.0 - hardness) * r, 1.0);
        const cos_a = @cos(dab.angle);
        const sin_a = @sin(dab.angle);
        const flow16: u32 = @intFromFloat(@round(flow * @as(f32, full)));

        var y = box.y0;
        while (y < box.y1) : (y += 1) {
            var x = box.x0;
            while (x < box.x1) : (x += 1) {
                // Pixel centres sit at half-pixel positions.
                const dx = @as(f32, @floatFromInt(x)) + 0.5 - dab.x;
                const dy = @as(f32, @floatFromInt(y)) + 0.5 - dab.y;
                // Turn the offset into the tip's own frame, then undo the
                // squash on the short axis (lessons 35 and 36).
                const u = dx * cos_a + dy * sin_a;
                const v = (dy * cos_a - dx * sin_a) / aspect;
                const d = @sqrt(u * u + v * v);
                if (d >= r) continue;

                // Lesson 34: 1 inside the solid part, falling to 0 at the
                // edge in a straight line.
                const cov = std.math.clamp((r - d) / fade, 0, 1);
                const add = (@as(u32, @intFromFloat(@round(cov * @as(f32, full)))) * flow16 + full / 2) / full;

                // Lesson 40: each dab covers part of what is still uncovered.
                // After n dabs of flow f the coverage is 1 - (1 - f)^n, which
                // approaches 1 and never passes it.
                //
                // The step is rounded up. Rounded to nearest, it becomes 0
                // once the gap is small, and coverage stops at 65534 however
                // many dabs land. Rounded up it cannot pass the gap, so it
                // still never goes over full.
                const i = @as(usize, y) * m.width + x;
                const old: u32 = m.coverage[i];
                m.coverage[i] = @intCast(old + ((full - old) * add + full - 1) / full);
            }
        }
        m.dirty = m.dirty.join(box);
    }
};

test "lesson 40: two dabs at 20% flow give 36%, not 40%" {
    var m = try Mask.init(std.testing.allocator, 32, 32);
    defer m.deinit(std.testing.allocator);
    const dab: Dab = .{ .x = 16, .y = 16, .radius = 10, .angle = 0 };
    m.stamp(dab, 1, 1, 0.2);
    m.stamp(dab, 1, 1, 0.2);
    const centre = @as(f32, @floatFromInt(m.at(16, 16))) / full;
    try std.testing.expectApproxEqAbs(@as(f32, 0.36), centre, 0.0001);
}

test "many dabs approach full coverage and never pass it" {
    var m = try Mask.init(std.testing.allocator, 16, 16);
    defer m.deinit(std.testing.allocator);
    for (0..200) |_| m.stamp(.{ .x = 8, .y = 8, .radius = 6, .angle = 0 }, 1, 1, 0.3);
    try std.testing.expectEqual(@as(u16, 65535), m.at(8, 8));
}

test "lesson 34: radius 20, hardness 0.6 is solid to 12 and half at 16" {
    var m = try Mask.init(std.testing.allocator, 64, 64);
    defer m.deinit(std.testing.allocator);
    // Centre on a pixel corner, so the pixel at (32 + k, 32) has its centre
    // k + 0.5 pixels from the dab.
    m.stamp(.{ .x = 32, .y = 32, .radius = 20, .angle = 0 }, 0.6, 1, 1);
    const at = struct {
        fn f(mm: Mask, k: u32) f32 {
            return @as(f32, @floatFromInt(mm.at(32 + k, 32))) / full;
        }
    }.f;
    try std.testing.expectEqual(@as(f32, 1), at(m, 11)); // 11.5 from the centre
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), at(m, 15), 0.07); // 15.5
    try std.testing.expectEqual(@as(f32, 0), at(m, 20)); // 20.5, outside
}

test "lesson 35: aspect 0.25 makes a tip 40 wide and 10 high" {
    var m = try Mask.init(std.testing.allocator, 64, 64);
    defer m.deinit(std.testing.allocator);
    m.stamp(.{ .x = 32, .y = 32, .radius = 20, .angle = 0 }, 1, 0.25, 1);
    try std.testing.expect(m.at(32 + 18, 32) > 0);
    try std.testing.expect(m.at(32, 32 + 6) == 0);
    try std.testing.expect(m.at(32, 32 + 3) > 0);
    // Turned a quarter turn, the same tip is tall instead of wide.
    var t = try Mask.init(std.testing.allocator, 64, 64);
    defer t.deinit(std.testing.allocator);
    t.stamp(.{ .x = 32, .y = 32, .radius = 20, .angle = std.math.pi / 2.0 }, 1, 0.25, 1);
    try std.testing.expect(t.at(32, 32 + 18) > 0);
    try std.testing.expect(t.at(32 + 6, 32) == 0);
}

test "a dab past the edge touches nothing outside the image" {
    var m = try Mask.init(std.testing.allocator, 8, 8);
    defer m.deinit(std.testing.allocator);
    m.stamp(.{ .x = -3, .y = 4, .radius = 5, .angle = 0 }, 1, 1, 1);
    try std.testing.expectEqual(Rect{ .x0 = 0, .y0 = 0, .x1 = 2, .y1 = 8 }, m.dirty);
    m.clear();
    for (m.coverage) |c| try std.testing.expectEqual(@as(u16, 0), c);
}
