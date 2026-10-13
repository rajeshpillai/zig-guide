//! From pointer samples to evenly spaced dabs.
//!
//! A pointer reports where it is whenever the system gets round to it. A fast
//! movement arrives as a few samples far apart, and a slow one as many samples
//! close together. If the brush put one mark at each sample, the stroke would
//! look different depending on how fast the hand moved.
//!
//! So the stroke walks along the path between samples and puts a dab every
//! `gap` pixels, whatever the samples were. The distance left over at the end
//! of one segment is carried into the next.

const std = @import("std");
const geometry = @import("geometry.zig");
const Point = geometry.Point;
const Brush = @import("brush.zig").Brush;
const Random = @import("random.zig").Random;

/// One mark of the tip, ready to draw.
pub const Dab = struct {
    x: f32,
    y: f32,
    radius: f32,
    /// Radians, measured from the x axis towards the y axis (down the page).
    angle: f32,
};

pub const Stroke = struct {
    brush: Brush,
    random: Random,
    /// The smoothed pointer position.
    filtered: Point,
    /// Where the last segment ended. Dabs are placed from here.
    last: Point,
    /// Distance walked since the last dab, in pixels. Always less than `gap`.
    carry: f32,
    /// Direction of travel, in radians. 0 (to the right) until the first move.
    direction: f32,

    /// Start a stroke at `p` and put the first dab there, so a click with no
    /// movement still leaves a mark.
    pub fn begin(brush: Brush, p: Point, sink: anytype) Stroke {
        const b = brush.sanitized();
        var s: Stroke = .{
            .brush = b,
            .random = .init(b.seed),
            .filtered = p,
            .last = p,
            .carry = 0,
            .direction = 0,
        };
        s.emit(p, sink);
        return s;
    }

    /// The pointer moved to `p`. Place every dab that falls on the way.
    pub fn move(s: *Stroke, p: Point, sink: anytype) void {
        // Smoothing: move part of the way towards the real point.
        s.filtered = geometry.lerpPoint(s.filtered, p, s.brush.follow);

        const a = s.last;
        const b = s.filtered;
        const d = geometry.distance(a, b);
        // Two samples at the same place: nothing to walk, and dividing by
        // `d` below would give NaN.
        if (d == 0) return;
        s.direction = std.math.atan2(b.y - a.y, b.x - a.x);

        const step = s.gap();
        // The first dab on this segment completes the interval left over from
        // the last one.
        var at = step - s.carry;
        while (at <= d) : (at += step) {
            s.emit(geometry.lerpPoint(a, b, at / d), sink);
        }
        s.carry = d - (at - step);
        s.last = b;
    }

    /// The gap between dabs, in pixels. Never below half a pixel, or a tiny
    /// brush would put thousands of dabs on one short segment.
    fn gap(s: Stroke) f32 {
        return @max(s.brush.spacing * s.brush.radius, 0.5);
    }

    fn emit(s: *Stroke, p: Point, sink: anytype) void {
        const b = s.brush;

        // Pressure: at `pressure = 0` the size ignores the pen.
        // At 1, a light touch draws at a quarter of the size.
        const p2 = p.pressure * p.pressure;
        var radius = b.radius * geometry.lerp(1.0, 0.25 + 0.75 * p2, b.pressure);

        // Three random numbers per dab, used or not, so that turning on
        // scatter does not change the size of every later dab.
        const u_size = s.random.next();
        const u_angle = s.random.next();
        const u_reach = s.random.next();

        radius *= 1.0 - b.jitter * u_size;

        // Scatter across a disc. The square root spreads the
        // offsets evenly over the area instead of bunching them at the centre.
        const theta = 2.0 * std.math.pi * u_angle;
        const reach = b.scatter * b.radius * @sqrt(u_reach);

        sink.dab(.{
            .x = p.x + @cos(theta) * reach,
            .y = p.y + @sin(theta) * reach,
            .radius = radius,
            // Following the direction, the brush angle is an offset from it:
            // 0 lays the tip along the stroke, 90 lays it across.
            .angle = (if (b.follow_direction) s.direction else 0) + b.angle * std.math.pi / 180.0,
        });
    }
};

/// A sink for tests: keeps the dabs it is given.
const Recorder = struct {
    dabs: [256]Dab = undefined,
    len: usize = 0,

    fn dab(r: *Recorder, d: Dab) void {
        r.dabs[r.len] = d;
        r.len += 1;
    }
};

test "carry after three moves of 6 pixels with a gap of 10 is 8" {
    // Radius 40 at spacing 0.25 is a gap of 10 pixels.
    const brush: Brush = .{ .radius = 40, .spacing = 0.25 };
    var rec: Recorder = .{};
    var s = Stroke.begin(brush, .{ .x = 0, .y = 0 }, &rec);
    s.move(.{ .x = 6, .y = 0 }, &rec);
    try std.testing.expectEqual(@as(f32, 6), s.carry);
    s.move(.{ .x = 12, .y = 0 }, &rec);
    s.move(.{ .x = 18, .y = 0 }, &rec);
    try std.testing.expectEqual(@as(f32, 8), s.carry);

    // A dab at the start, and one at x = 10. Not one per sample.
    try std.testing.expectEqual(@as(usize, 2), rec.len);
    try std.testing.expectEqual(@as(f32, 0), rec.dabs[0].x);
    try std.testing.expectApproxEqAbs(@as(f32, 10), rec.dabs[1].x, 1e-4);
}

test "the spacing does not depend on how the movement was cut up" {
    const brush: Brush = .{ .radius = 20, .spacing = 0.25 };
    var one: Recorder = .{};
    var s1 = Stroke.begin(brush, .{ .x = 0, .y = 0 }, &one);
    s1.move(.{ .x = 100, .y = 0 }, &one);

    var many: Recorder = .{};
    var s2 = Stroke.begin(brush, .{ .x = 0, .y = 0 }, &many);
    var x: f32 = 0;
    while (x < 100) {
        x = @min(x + 3, 100);
        s2.move(.{ .x = x, .y = 0 }, &many);
    }

    try std.testing.expectEqual(one.len, many.len);
    for (one.dabs[0..one.len], many.dabs[0..many.len]) |a, b| {
        try std.testing.expectApproxEqAbs(a.x, b.x, 1e-3);
    }
}

test "a repeated sample adds no dab and does not divide by zero" {
    var rec: Recorder = .{};
    var s = Stroke.begin(.{}, .{ .x = 5, .y = 5 }, &rec);
    s.move(.{ .x = 5, .y = 5 }, &rec);
    try std.testing.expectEqual(@as(usize, 1), rec.len);
    try std.testing.expect(!std.math.isNan(s.carry));
}

test "smoothing moves a quarter of the way" {
    var rec: Recorder = .{};
    var s = Stroke.begin(.{ .follow = 0.25 }, .{ .x = 100, .y = 0 }, &rec);
    s.move(.{ .x = 120, .y = 0 }, &rec);
    try std.testing.expectEqual(@as(f32, 105), s.filtered.x);
    s.move(.{ .x = 120, .y = 0 }, &rec);
    try std.testing.expectEqual(@as(f32, 108.75), s.filtered.x);
}

test "pressure: ignored at 0, a quarter size at full effect and no pressure" {
    var rec: Recorder = .{};
    _ = Stroke.begin(.{ .radius = 20, .pressure = 0 }, .{ .x = 0, .y = 0, .pressure = 0 }, &rec);
    _ = Stroke.begin(.{ .radius = 20, .pressure = 1 }, .{ .x = 0, .y = 0, .pressure = 0 }, &rec);
    _ = Stroke.begin(.{ .radius = 20, .pressure = 1 }, .{ .x = 0, .y = 0, .pressure = 1 }, &rec);
    try std.testing.expectEqual(@as(f32, 20), rec.dabs[0].radius);
    try std.testing.expectEqual(@as(f32, 5), rec.dabs[1].radius);
    try std.testing.expectEqual(@as(f32, 20), rec.dabs[2].radius);
}

test "scatter stays inside the disc, and the same seed repeats it" {
    const brush: Brush = .{ .radius = 10, .scatter = 2, .seed = 7 };
    var a: Recorder = .{};
    var b: Recorder = .{};
    var sa = Stroke.begin(brush, .{ .x = 0, .y = 0 }, &a);
    var sb = Stroke.begin(brush, .{ .x = 0, .y = 0 }, &b);
    sa.move(.{ .x = 200, .y = 0 }, &a);
    sb.move(.{ .x = 200, .y = 0 }, &b);
    try std.testing.expectEqual(a.len, b.len);
    for (a.dabs[0..a.len], b.dabs[0..b.len], 0..) |da, db, i| {
        try std.testing.expectEqual(da, db);
        // The dab's place on the path, before scatter, is i * gap.
        const along: f32 = @as(f32, @floatFromInt(i)) * 2.5;
        const off = std.math.hypot(da.x - along, da.y);
        try std.testing.expect(off <= 20.001);
    }
}

test "a tip that follows direction points down for a downward move" {
    var rec: Recorder = .{};
    var s = Stroke.begin(.{ .follow_direction = true, .radius = 4 }, .{ .x = 0, .y = 0 }, &rec);
    s.move(.{ .x = 0, .y = 10 }, &rec);
    try std.testing.expectApproxEqAbs(std.math.pi / 2.0, rec.dabs[rec.len - 1].angle, 1e-6);
}
