//! Points, distances and rectangles, in document pixels.
//!
//! Positions are `f32`, because a pointer reports positions between pixels
//! and a stroke drawn through those positions is smoother than one snapped to
//! whole pixels. Rectangles are whole pixels, because they describe which
//! pixels to touch.

const std = @import("std");

/// One input sample: where the pointer was, and how hard it pressed.
/// A mouse reports pressure 0.5 while a button is held.
pub const Point = struct {
    x: f32,
    y: f32,
    pressure: f32 = 0.5,
};

/// Straight-line distance, in pixels. Moving backwards gives the same distance.
pub fn distance(a: Point, b: Point) f32 {
    return std.math.hypot(b.x - a.x, b.y - a.y);
}

/// The value a fraction `t` of the way from `a` to `b`. `t` is not clamped:
/// `t = 1.5` goes past `b`.
pub fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

pub fn lerpPoint(a: Point, b: Point, t: f32) Point {
    return .{
        .x = lerp(a.x, b.x, t),
        .y = lerp(a.y, b.y, t),
        .pressure = lerp(a.pressure, b.pressure, t),
    };
}

/// A rectangle of pixels: `x0 <= x < x1` and `y0 <= y < y1`.
/// An empty rectangle has `x0 >= x1` or `y0 >= y1`.
pub const Rect = struct {
    x0: u32,
    y0: u32,
    x1: u32,
    y1: u32,

    pub const empty: Rect = .{ .x0 = 0, .y0 = 0, .x1 = 0, .y1 = 0 };

    pub fn isEmpty(r: Rect) bool {
        return r.x0 >= r.x1 or r.y0 >= r.y1;
    }

    pub fn width(r: Rect) u32 {
        return if (r.isEmpty()) 0 else r.x1 - r.x0;
    }

    pub fn height(r: Rect) u32 {
        return if (r.isEmpty()) 0 else r.y1 - r.y0;
    }

    pub fn area(r: Rect) usize {
        return @as(usize, r.width()) * r.height();
    }

    /// The smallest rectangle holding both.
    pub fn join(a: Rect, b: Rect) Rect {
        if (a.isEmpty()) return b;
        if (b.isEmpty()) return a;
        return .{
            .x0 = @min(a.x0, b.x0),
            .y0 = @min(a.y0, b.y0),
            .x1 = @max(a.x1, b.x1),
            .y1 = @max(a.y1, b.y1),
        };
    }

    /// The pixels a circle of `radius` around (`x`, `y`) can touch, cut to a
    /// `w` by `h` image. Computed in `f32` and clamped before converting,
    /// because a dab can start far outside the image.
    pub fn around(x: f32, y: f32, radius: f32, w: u32, h: u32) Rect {
        const fw: f32 = @floatFromInt(w);
        const fh: f32 = @floatFromInt(h);
        return .{
            .x0 = @intFromFloat(std.math.clamp(@floor(x - radius), 0, fw)),
            .y0 = @intFromFloat(std.math.clamp(@floor(y - radius), 0, fh)),
            .x1 = @intFromFloat(std.math.clamp(@ceil(x + radius), 0, fw)),
            .y1 = @intFromFloat(std.math.clamp(@ceil(y + radius), 0, fh)),
        };
    }
};

test "distance: the 3-4-5 triangle" {
    const a: Point = .{ .x = 10, .y = 20 };
    const b: Point = .{ .x = 40, .y = 60 };
    try std.testing.expectEqual(@as(f32, 50), distance(a, b));
    try std.testing.expectEqual(@as(f32, 50), distance(b, a));
}

test "lerp: endpoints, a quarter, and past the end" {
    try std.testing.expectEqual(@as(f32, 20), lerp(20, 100, 0));
    try std.testing.expectEqual(@as(f32, 40), lerp(20, 100, 0.25));
    try std.testing.expectEqual(@as(f32, 100), lerp(20, 100, 1));
    try std.testing.expectEqual(@as(f32, 140), lerp(20, 100, 1.5));
}

test "a rectangle around a dab is cut to the image" {
    const r = Rect.around(-5, 3, 10, 64, 32);
    try std.testing.expectEqual(Rect{ .x0 = 0, .y0 = 0, .x1 = 5, .y1 = 13 }, r);
    try std.testing.expect(Rect.around(-50, -50, 10, 64, 32).isEmpty());
}

test "join ignores an empty rectangle" {
    const a: Rect = .{ .x0 = 2, .y0 = 2, .x1 = 4, .y1 = 4 };
    try std.testing.expectEqual(a, Rect.join(.empty, a));
    try std.testing.expectEqual(Rect{ .x0 = 1, .y0 = 2, .x1 = 4, .y1 = 9 }, a.join(.{ .x0 = 1, .y0 = 5, .x1 = 3, .y1 = 9 }));
}
