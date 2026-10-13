//! Brush settings, and the one place they are checked.
//!
//! Settings arrive from sliders, from a preset file, or from a test. Each of
//! those can hold a value the engine cannot use: a negative radius, a flow of
//! 7, or NaN from a slider that was never set. `sanitized` turns any `Brush`
//! into a usable one, so the drawing code never has to check again.

const std = @import("std");

/// The most hairs a bristle brush can have.
pub const max_bristles = 16;

pub const Brush = struct {
    /// Radius of the tip, in pixels, at full size.
    radius: f32 = 12,
    /// The solid part of the tip, as a fraction of the radius. 1 is a hard
    /// disc. Lower values leave a wider fading edge.
    hardness: f32 = 0.6,
    /// How much one dab adds to the stroke, 0 to 1.
    flow: f32 = 0.5,
    /// How much the finished stroke covers what is below it, 0 to 1.
    opacity: f32 = 1,
    /// The gap between dabs, as a fraction of the radius.
    spacing: f32 = 0.25,
    /// Smoothing. Each new position moves this fraction of the way from the
    /// smoothed position to the real one. 1 means no smoothing.
    follow: f32 = 1,
    /// How much pen pressure changes the size, 0 to 1. At 0 pressure is
    /// ignored.
    pressure: f32 = 0,
    /// Random size change per dab, 0 to 1.
    jitter: f32 = 0,
    /// Random offset per dab, as a fraction of the radius.
    scatter: f32 = 0,
    /// Height of the tip divided by its width. 1 is round.
    aspect: f32 = 1,
    /// Angle of the tip in degrees. With `follow_direction` it is measured
    /// from the direction of travel instead of from the page.
    angle: f32 = 0,
    /// Turn the tip with the stroke.
    follow_direction: bool = false,
    /// How much of the paper the brush reaches, 0 to 1. At 1 it paints
    /// everywhere. Lower values paint only the hills of the paper's grain,
    /// like a dry brush.
    contact: f32 = 1,
    /// Separate hairs across the tip, each leaving its own track. 0 means a
    /// solid tip.
    bristles: u32 = 0,
    /// The paint colour, as stored sRGB bytes.
    color: [3]u8 = .{ 0x26, 0x33, 0x4d },
    /// Seed for jitter and scatter. The same seed repeats the same marks.
    seed: u32 = 1,

    /// The same brush with every number moved into a range the engine can
    /// draw with. NaN becomes the default for that field.
    pub fn sanitized(b: Brush) Brush {
        const d: Brush = .{};
        return .{
            .radius = fix(b.radius, d.radius, 0.5, 500),
            .hardness = fix(b.hardness, d.hardness, 0, 1),
            .flow = fix(b.flow, d.flow, 0, 1),
            .opacity = fix(b.opacity, d.opacity, 0, 1),
            .spacing = fix(b.spacing, d.spacing, 0.02, 10),
            .follow = fix(b.follow, d.follow, 0.05, 1),
            .pressure = fix(b.pressure, d.pressure, 0, 1),
            .jitter = fix(b.jitter, d.jitter, 0, 1),
            .scatter = fix(b.scatter, d.scatter, 0, 10),
            .aspect = fix(b.aspect, d.aspect, 0.05, 1),
            .angle = fix(b.angle, d.angle, -360, 360),
            .follow_direction = b.follow_direction,
            .contact = fix(b.contact, d.contact, 0, 1),
            .bristles = @min(b.bristles, max_bristles),
            .color = b.color,
            .seed = b.seed,
        };
    }
};

fn fix(value: f32, default: f32, low: f32, high: f32) f32 {
    if (std.math.isNan(value)) return default;
    return std.math.clamp(value, low, high);
}

test "sanitized clamps, and replaces NaN with the default" {
    const b = (Brush{ .radius = -3, .flow = 7, .hardness = std.math.nan(f32) }).sanitized();
    try std.testing.expectEqual(@as(f32, 0.5), b.radius);
    try std.testing.expectEqual(@as(f32, 1), b.flow);
    try std.testing.expectEqual((Brush{}).hardness, b.hardness);
}

test "infinity is clamped like any other number" {
    const b = (Brush{ .radius = std.math.inf(f32) }).sanitized();
    try std.testing.expectEqual(@as(f32, 500), b.radius);
}
