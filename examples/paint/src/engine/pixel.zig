//! One pixel of a layer, and the three ways the engine changes one.
//!
//! Layers store **premultiplied** alpha: the colour channels are already
//! multiplied by the alpha. A half-covered red pixel is (128, 0, 0, 128), not
//! (255, 0, 0, 128).
//!
//! The reason is the eraser. Erasing means "keep less of this pixel", and with
//! premultiplied values that is one multiply on all four channels. A fully
//! erased pixel comes out as (0, 0, 0, 0) with no colour left behind in it,
//! so it cannot reappear later at the edge of a blend.

const std = @import("std");

/// `extern` fixes the field order in memory. A row of these values has the
/// R, G, B, A bytes in the order that a browser canvas expects. Thus the
/// display needs no conversion.
pub const Rgba = extern struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,

    pub const transparent: Rgba = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
    pub const white: Rgba = .{ .r = 255, .g = 255, .b = 255, .a = 255 };

    pub fn opaqueRgb(c: [3]u8) Rgba {
        return .{ .r = c[0], .g = c[1], .b = c[2], .a = 255 };
    }
};

/// 16-bit coverage, the same scale as the stroke buffer: 65535 is full.
pub const full: u32 = 65535;

/// `value * amount / 65535`, rounded to nearest.
fn scale(value: u32, amount: u32) u32 {
    return (value * amount + full / 2) / full;
}

/// `top` over `below`, both premultiplied. This is the operator from the
/// Alpha Blending chapter, without its multiply: the colour in `top` is
/// already scaled by its alpha.
pub fn over(top: Rgba, below: Rgba) Rgba {
    const keep = (255 - @as(u32, top.a)) * 257; // 255 * 257 = 65535
    return .{
        .r = @intCast(top.r + scale(below.r, keep)),
        .g = @intCast(top.g + scale(below.g, keep)),
        .b = @intCast(top.b + scale(below.b, keep)),
        .a = @intCast(top.a + scale(below.a, keep)),
    };
}

/// Lay `color` over `dst` with coverage `amount` (0 to 65535).
pub fn paint(dst: Rgba, color: [3]u8, amount: u32) Rgba {
    const keep = full - amount;
    return .{
        .r = @intCast(scale(color[0], amount) + scale(dst.r, keep)),
        .g = @intCast(scale(color[1], amount) + scale(dst.g, keep)),
        .b = @intCast(scale(color[2], amount) + scale(dst.b, keep)),
        .a = @intCast(scale(255, amount) + scale(dst.a, keep)),
    };
}

/// Remove `amount` (0 to 65535) of `dst`. White paint and the eraser look
/// the same on white paper. Over another layer, white covers it and the
/// eraser reveals it.
pub fn erase(dst: Rgba, amount: u32) Rgba {
    const keep = full - amount;
    return .{
        .r = @intCast(scale(dst.r, keep)),
        .g = @intCast(scale(dst.g, keep)),
        .b = @intCast(scale(dst.b, keep)),
        .a = @intCast(scale(dst.a, keep)),
    };
}

test "coverage 0 changes nothing" {
    const p: Rgba = .{ .r = 10, .g = 20, .b = 30, .a = 40 };
    try std.testing.expectEqual(p, paint(p, .{ 255, 0, 0 }, 0));
    try std.testing.expectEqual(p, erase(p, 0));
}

test "full coverage replaces, full erase leaves nothing" {
    const p: Rgba = .{ .r = 10, .g = 20, .b = 30, .a = 40 };
    try std.testing.expectEqual(Rgba.opaqueRgb(.{ 1, 2, 3 }), paint(p, .{ 1, 2, 3 }, full));
    try std.testing.expectEqual(Rgba.transparent, erase(p, full));
}

test "half red on an empty layer is stored premultiplied" {
    const p = paint(.transparent, .{ 255, 0, 0 }, full / 2 + 1);
    try std.testing.expectEqual(Rgba{ .r = 128, .g = 0, .b = 0, .a = 128 }, p);
}

test "an opaque top hides the bottom, a transparent top shows it" {
    const red: Rgba = .opaqueRgb(.{ 255, 0, 0 });
    try std.testing.expectEqual(red, over(red, .white));
    try std.testing.expectEqual(Rgba.white, over(.transparent, .white));
}

test "half red over white is pink" {
    const half_red: Rgba = .{ .r = 128, .g = 0, .b = 0, .a = 128 };
    try std.testing.expectEqual(Rgba{ .r = 255, .g = 127, .b = 127, .a = 255 }, over(half_red, .white));
}

test "paint never overflows a byte, at any coverage" {
    // The sum of the two rounded parts is 255 or less. The sum of their
    // exact values is 255. Both parts can round up only if both end in
    // exactly .5, and `amount / 257` never does. This test examines the
    // claim. It does not trust it.
    var amount: u32 = 0;
    while (amount <= full) : (amount += 1) {
        const out = paint(.white, .{ 255, 255, 255 }, amount);
        try std.testing.expectEqual(@as(u8, 255), out.a);
        try std.testing.expectEqual(@as(u8, 255), out.r);
    }
}

test "over never overflows a byte" {
    // Premultiplied values satisfy channel <= alpha. Check every alpha with
    // the largest channels it allows, against the largest background.
    for (0..256) |a| {
        const top: Rgba = .{ .r = @intCast(a), .g = @intCast(a), .b = @intCast(a), .a = @intCast(a) };
        const out = over(top, .white);
        try std.testing.expectEqual(@as(u8, 255), out.a);
    }
}
