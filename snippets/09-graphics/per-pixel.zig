//! title: Per-Pixel Transforms
//! A point operation reads one pixel and nothing else. On 8-bit channels that
//! means there are only 256 possible answers, which turns the whole family into
//! one table lookup.

const std = @import("std");
const canvas = @import("_canvas.zig");

var pixels: [canvas.width * canvas.height]u32 = undefined;

/// Every answer a point operation can give, indexed by the input value.
const Lut = [256]u8;

fn identity() Lut {
    var lut: Lut = undefined;
    for (&lut, 0..) |*v, i| v.* = @intCast(i);
    return lut;
}

fn invert() Lut {
    var lut: Lut = undefined;
    for (&lut, 0..) |*v, i| v.* = @intCast(255 - i);
    return lut;
}

/// Brightness is an add, and the add is the interesting part.
///
/// `+|` and `-|` are saturating: they clamp at the type's bounds instead of
/// wrapping. Plain `+` on a `u8` at 250 + 10 is illegal behaviour in Zig and
/// traps in a safe build, and `+%` would wrap 250 + 10 round to 4, which is how
/// a naive brightness filter puts black speckles in a white sky.
fn brightness(delta: i16) Lut {
    var lut: Lut = undefined;
    for (&lut, 0..) |*v, i| {
        const value: u8 = @intCast(i);
        v.* = if (delta >= 0)
            value +| @as(u8, @intCast(delta))
        else
            value -| @as(u8, @intCast(-delta));
    }
    return lut;
}

/// Contrast pivots around mid-grey: values above 128 move up, values below move
/// down, and 128 stays put. `factor` is scaled by 256, so 256 is no change and
/// 512 is double contrast.
///
/// This one genuinely can overflow in both directions, so it clamps in a wider
/// type rather than saturating in `u8`. Saturating a `u8` cannot help when the
/// intermediate is already negative.
fn contrast(factor: i32) Lut {
    var lut: Lut = undefined;
    for (&lut, 0..) |*v, i| {
        const centred = @as(i32, @intCast(i)) - 128;
        const scaled = @divTrunc(centred * factor, 256) + 128;
        v.* = @intCast(std.math.clamp(scaled, 0, 255));
    }
    return lut;
}

fn threshold(cut: u8) Lut {
    var lut: Lut = undefined;
    for (&lut, 0..) |*v, i| v.* = if (i >= cut) 255 else 0;
    return lut;
}

/// Two tables become one. `compose(b, a)` is "apply a, then b", so a chain of
/// point operations costs one table build and one pass over the image no matter
/// how long the chain gets.
fn compose(second: Lut, first: Lut) Lut {
    var lut: Lut = undefined;
    for (&lut, 0..) |*v, i| v.* = second[first[i]];
    return lut;
}

/// One pass, three lookups. The image is the loop bound; the table is not.
fn apply(buf: []u32, lut: Lut) void {
    for (buf) |*p| {
        const c = canvas.channels(p.*);
        p.* = canvas.rgb(lut[c.r], lut[c.g], lut[c.b]);
    }
}

/// Grayscale is the point operation that is *not* a per-channel table: the
/// output channel depends on all three inputs, so there are 2^24 possible
/// answers rather than 256.
fn grayscale(buf: []u32) void {
    for (buf) |*p| {
        const y: u8 = @intCast(canvas.luma(p.*));
        p.* = canvas.rgb(y, y, y);
    }
}

pub fn main(init: std.process.Init) !void {
    var buf: [16384]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    canvas.scene(&pixels);
    try out.writeAll("original:\n");
    try canvas.dump(out, &pixels);

    // Lift, then stretch around mid-grey. Built as one table, applied once.
    // The background ramp is pushed to black and the block to white: contrast
    // does not create detail, it spends the range it has on the middle.
    const chain = compose(contrast(400), brightness(30));
    apply(&pixels, chain);
    try out.writeAll("\nbrightness(+30) then contrast(x1.56):\n");
    try canvas.dump(out, &pixels);

    // A table is worth printing. These five columns are entire filters.
    const tables = [_]struct { name: []const u8, lut: Lut }{
        .{ .name = "ident", .lut = identity() },
        .{ .name = "invert", .lut = invert() },
        .{ .name = "+40", .lut = brightness(40) },
        .{ .name = "x2", .lut = contrast(512) },
        .{ .name = "thresh", .lut = threshold(128) },
    };
    try out.writeAll("\n  in |");
    for (tables) |t| try out.print(" {s:>6}", .{t.name});
    try out.writeByte('\n');
    for ([_]u8{ 0, 64, 128, 192, 255 }) |v| {
        try out.print(" {d:>3} |", .{v});
        for (tables) |t| try out.print(" {d:>6}", .{t.lut[v]});
        try out.writeByte('\n');
    }

    // Saturating versus wrapping, on the one value where it shows.
    const near_white: u8 = 250;
    try out.print("\n250 +| 10 = {d}   250 +% 10 = {d}\n", .{
        near_white +| @as(u8, 10),
        near_white +% @as(u8, 10),
    });

    // Composition is exact, not an approximation: the table built from two
    // tables gives the same answer as running both passes.
    const a = brightness(30);
    const b = contrast(400);
    var mismatches: usize = 0;
    for (0..256) |i| {
        if (compose(b, a)[i] != b[a[i]]) mismatches += 1;
    }
    try out.print("composed table differs from two passes at {d} of 256 inputs\n", .{mismatches});

    canvas.scene(&pixels);
    grayscale(&pixels);
    const before = canvas.channels(canvas.rgb(230, 40, 40));
    try out.print("\nluma of the red disc: {d} (not (r+g+b)/3 = {d})\n", .{
        canvas.luma(canvas.rgb(230, 40, 40)),
        (@as(u32, before.r) + before.g + before.b) / 3,
    });

    try out.flush();
}
