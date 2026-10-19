//! The stroke buffer: how much of each pixel the stroke in progress covers.
//!
//! Dabs are not drawn straight onto the layer. They build up coverage here,
//! one number per pixel, and the whole stroke is put onto the layer once, at
//! the end, with the stroke's opacity.
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
const Paper = @import("paper.zig").Paper;

pub const full: u32 = 65535;

pub const Mask = struct {
    width: u32,
    height: u32,
    coverage: []u16,
    /// The colour that the stroke puts at each pixel. For most brushes, it is
    /// the brush colour at all pixels. A brush with pickup changes colour
    /// along the stroke. Thus the buffer must keep the colour for each pixel.
    /// The value has a meaning only where `coverage` is above 0. Thus the
    /// code never clears it.
    color: [][3]u8,
    /// Each pixel outside this rectangle is 0. With this rectangle, the
    /// commit, the clear and the redraw touch only the part of the image that
    /// the stroke touched.
    dirty: Rect = .empty,

    pub fn init(gpa: std.mem.Allocator, width: u32, height: u32) !Mask {
        const coverage = try gpa.alloc(u16, @as(usize, width) * height);
        errdefer gpa.free(coverage);
        @memset(coverage, 0);
        const color = try gpa.alloc([3]u8, @as(usize, width) * height);
        return .{ .width = width, .height = height, .coverage = coverage, .color = color };
    }

    pub fn deinit(m: *Mask, gpa: std.mem.Allocator) void {
        gpa.free(m.color);
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
    /// `hardness` is the solid fraction of the radius, `aspect` makes the tip
    /// an ellipse, and `flow` is how much one dab adds.
    pub fn stamp(m: *Mask, dab: Dab, hardness: f32, aspect: f32, flow: f32) void {
        m.stampOn(null, 1, dab, hardness, aspect, flow);
    }

    /// `stamp`, on paper. Where the `contact` of the brush does not reach the
    /// height of the paper, the pixel gets no paint.
    pub fn stampOn(m: *Mask, paper: ?*const Paper, contact: f32, dab: Dab, hardness: f32, aspect: f32, flow: f32) void {
        const r = dab.radius;
        const box = Rect.around(dab.x, dab.y, r, m.width, m.height);
        if (box.isEmpty() or flow <= 0) return;

        // The soft band at the edge. A hard tip still gets one pixel of the
        // band. Without it, the edge would be a staircase.
        const fade = @max((1.0 - hardness) * r, 1.0);
        const cos_a = @cos(dab.angle);
        const sin_a = @sin(dab.angle);
        // When the brush becomes dry, each dab puts less paint.
        const flow16: u32 = @intFromFloat(@round(flow * dab.load * @as(f32, full)));

        var y = box.y0;
        while (y < box.y1) : (y += 1) {
            var x = box.x0;
            while (x < box.x1) : (x += 1) {
                // Pixel centres sit at half-pixel positions.
                const dx = @as(f32, @floatFromInt(x)) + 0.5 - dab.x;
                const dy = @as(f32, @floatFromInt(y)) + 0.5 - dab.y;
                // Turn the offset into the frame of the tip. Then divide by the
                // aspect on the short axis.
                const u = dx * cos_a + dy * sin_a;
                const v = (dy * cos_a - dx * sin_a) / aspect;
                const d = @sqrt(u * u + v * v);
                if (d >= r) continue;
                if (paper) |pp| if (!pp.touches(x, y, contact)) continue;

                // Coverage is 1 inside the solid part. It decreases to 0 at the
                // edge in a straight line.
                const cov = std.math.clamp((r - d) / fade, 0, 1);
                const add = (@as(u32, @intFromFloat(@round(cov * @as(f32, full)))) * flow16 + full / 2) / full;

                // Each dab covers part of the area that has no coverage yet.
                // After n dabs of flow f, the coverage is 1 - (1 - f)^n. The value
                // moves nearer to 1 and never goes past 1.
                //
                // The code rounds the step up. With rounding to the nearest value, the
                // step becomes 0 when the gap is small. Then the coverage stops at 65534
                // for any number of dabs. A step that the code rounds up cannot be larger
                // than the gap. Thus the coverage still never goes over full.
                const i = @as(usize, y) * m.width + x;
                const old: u32 = m.coverage[i];
                const new = old + ((full - old) * add + full - 1) / full;
                m.coverage[i] = @intCast(new);

                // The colour is the average of the old colour and the colour of the
                // dab. The weight of each colour is the coverage that it added. Paint of
                // the dab over the old colour gives the same result. When the two
                // colours are the same, the average is exactly that colour.
                const added = new - old;
                if (added > 0) {
                    for (&m.color[i], dab.color) |*c, fresh| {
                        c.* = @intCast((@as(u32, c.*) * old + @as(u32, fresh) * added + new / 2) / new);
                    }
                }
            }
        }
        m.dirty = m.dirty.join(box);
    }
};

test "two dabs at 20% flow give 36%, not 40%" {
    var m = try Mask.init(std.testing.allocator, 32, 32);
    defer m.deinit(std.testing.allocator);
    const dab: Dab = .{ .x = 16, .y = 16, .radius = 10, .angle = 0, .direction = 0, .color = .{ 0, 0, 0 }, .load = 1 };
    m.stamp(dab, 1, 1, 0.2);
    m.stamp(dab, 1, 1, 0.2);
    const centre = @as(f32, @floatFromInt(m.at(16, 16))) / full;
    try std.testing.expectApproxEqAbs(@as(f32, 0.36), centre, 0.0001);
}

test "many dabs approach full coverage and never pass it" {
    var m = try Mask.init(std.testing.allocator, 16, 16);
    defer m.deinit(std.testing.allocator);
    for (0..200) |_| m.stamp(.{ .x = 8, .y = 8, .radius = 6, .angle = 0, .direction = 0, .color = .{ 0, 0, 0 }, .load = 1 }, 1, 1, 0.3);
    try std.testing.expectEqual(@as(u16, 65535), m.at(8, 8));
}

test "radius 20, hardness 0.6 is solid to 12 and half at 16" {
    var m = try Mask.init(std.testing.allocator, 64, 64);
    defer m.deinit(std.testing.allocator);
    // Put the centre on a pixel corner. Then the centre of the pixel at
    // (32 + k, 32) is k + 0.5 pixels from the dab.
    m.stamp(.{ .x = 32, .y = 32, .radius = 20, .angle = 0, .direction = 0, .color = .{ 0, 0, 0 }, .load = 1 }, 0.6, 1, 1);
    const at = struct {
        fn f(mm: Mask, k: u32) f32 {
            return @as(f32, @floatFromInt(mm.at(32 + k, 32))) / full;
        }
    }.f;
    try std.testing.expectEqual(@as(f32, 1), at(m, 11)); // 11.5 from the centre
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), at(m, 15), 0.07); // 15.5
    try std.testing.expectEqual(@as(f32, 0), at(m, 20)); // 20.5, outside
}

test "aspect 0.25 makes a tip 40 wide and 10 high" {
    var m = try Mask.init(std.testing.allocator, 64, 64);
    defer m.deinit(std.testing.allocator);
    m.stamp(.{ .x = 32, .y = 32, .radius = 20, .angle = 0, .direction = 0, .color = .{ 0, 0, 0 }, .load = 1 }, 1, 0.25, 1);
    try std.testing.expect(m.at(32 + 18, 32) > 0);
    try std.testing.expect(m.at(32, 32 + 6) == 0);
    try std.testing.expect(m.at(32, 32 + 3) > 0);
    // After a quarter turn, the same tip is tall, not wide.
    var t = try Mask.init(std.testing.allocator, 64, 64);
    defer t.deinit(std.testing.allocator);
    t.stamp(.{ .x = 32, .y = 32, .radius = 20, .angle = std.math.pi / 2.0, .direction = 0, .color = .{ 0, 0, 0 }, .load = 1 }, 1, 0.25, 1);
    try std.testing.expect(t.at(32, 32 + 18) > 0);
    try std.testing.expect(t.at(32 + 6, 32) == 0);
}

test "a dab past the edge touches nothing outside the image" {
    var m = try Mask.init(std.testing.allocator, 8, 8);
    defer m.deinit(std.testing.allocator);
    m.stamp(.{ .x = -3, .y = 4, .radius = 5, .angle = 0, .direction = 0, .color = .{ 0, 0, 0 }, .load = 1 }, 1, 1, 1);
    try std.testing.expectEqual(Rect{ .x0 = 0, .y0 = 0, .x1 = 2, .y1 = 8 }, m.dirty);
    m.clear();
    for (m.coverage) |c| try std.testing.expectEqual(@as(u16, 0), c);
}

test "two colours mix by the coverage each one added" {
    var m = try Mask.init(std.testing.allocator, 16, 16);
    defer m.deinit(std.testing.allocator);
    const at: Dab = .{ .x = 8, .y = 8, .radius = 6, .angle = 0, .direction = 0, .color = .{ 200, 0, 0 }, .load = 1 };
    m.stamp(at, 1, 1, 0.5);
    var blue = at;
    blue.color = .{ 0, 0, 200 };
    m.stamp(blue, 1, 1, 0.5);
    // Red covered half, then blue covered half of the remainder. Red added
    // two times as much as blue.
    const c = m.color[8 * 16 + 8];
    try std.testing.expectEqual([3]u8{ 133, 0, 67 }, c);
}

test "a dry brush adds nothing" {
    var m = try Mask.init(std.testing.allocator, 16, 16);
    defer m.deinit(std.testing.allocator);
    m.stamp(.{ .x = 8, .y = 8, .radius = 6, .angle = 0, .direction = 0, .color = .{ 1, 2, 3 }, .load = 0 }, 1, 1, 1);
    try std.testing.expectEqual(@as(u16, 0), m.at(8, 8));
}
