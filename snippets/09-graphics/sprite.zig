//! title: Sprites and Transparency
//! Copying a rectangle is easy. Deciding which pixels not to copy is the feature.

const std = @import("std");

const width: usize = 40;
const height: usize = 14;
var canvas: [width * height]u8 = @splat('.');

/// A sprite is a small image plus a rule for which pixels are see-through.
/// Here the rule is a key colour: one value declared to mean "skip". That is
/// how every 8-bit and 16-bit console did it, because a per-pixel alpha
/// channel costs memory those machines did not have.
const Sprite = struct {
    w: usize,
    h: usize,
    pixels: []const u8,
    transparent: u8,
};

const ship = Sprite{
    .w = 7,
    .h = 5,
    .transparent = ' ',
    .pixels = "   A   " ++
        "  AAA  " ++
        " AABAA " ++
        "AAAAAAA" ++
        " A   A ",
};

fn blit(sprite: Sprite, x: i32, y: i32) void {
    for (0..sprite.h) |sy| {
        for (0..sprite.w) |sx| {
            const value = sprite.pixels[sy * sprite.w + sx];
            // The whole of transparency, in one comparison. Without it a
            // sprite is a rectangle and everything behind its corners is gone.
            if (value == sprite.transparent) continue;

            const dx = x + @as(i32, @intCast(sx));
            const dy = y + @as(i32, @intCast(sy));
            if (dx < 0 or dy < 0) continue;
            const ux: usize = @intCast(dx);
            const uy: usize = @intCast(dy);
            if (ux >= width or uy >= height) continue;

            canvas[uy * width + ux] = value;
        }
    }
}

fn fillBackground() void {
    for (0..height) |y| {
        for (0..width) |x| {
            canvas[y * width + x] = if ((x / 4 + y / 2) % 2 == 0) '.' else ',';
        }
    }
}

fn dump(out: *std.Io.Writer) !void {
    for (0..height) |y| try out.print("{s}\n", .{canvas[y * width ..][0..width]});
}

pub fn main(init: std.process.Init) !void {
    var buf: [4096]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    fillBackground();

    // Three copies of one sprite. Nothing is duplicated in memory: a sprite is
    // data, and drawing it is a loop, so the second copy costs nothing.
    blit(ship, 2, 2);
    blit(ship, 14, 6);
    // Deliberately over the edge, to show the clipping.
    blit(ship, 36, 9);

    try dump(out);

    try out.print("\nthe sprite is {d}x{d} = {d} bytes\n", .{ ship.w, ship.h, ship.w * ship.h });
    var opaque_count: usize = 0;
    for (ship.pixels) |p| {
        if (p != ship.transparent) opaque_count += 1;
    }
    try out.print("{d} of those pixels are drawn, {d} are skipped\n", .{
        opaque_count,
        ship.w * ship.h - opaque_count,
    });

    try out.flush();
}
