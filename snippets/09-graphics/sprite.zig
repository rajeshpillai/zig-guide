//! title: Sprites and Transparency
//! A copy of a rectangle is easy. The feature is the decision about which pixels not to copy.

const std = @import("std");

const width: usize = 40;
const height: usize = 14;
var canvas: [width * height]u8 = @splat('.');

/// A sprite is a small image and a rule for the pixels that are transparent.
/// Here the rule is a key colour: one value that means "skip". The 8-bit and
/// 16-bit consoles used this method, because a per-pixel alpha channel costs
/// memory that those machines did not have.
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
            // All of transparency is this one comparison. Without it, a
            // sprite is a rectangle, and the sprite hides all of the pixels
            // behind its corners.
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

    // Three copies of one sprite. The program does not copy the data in
    // memory. A sprite is data, and a loop draws it. Thus the second copy
    // costs no memory.
    blit(ship, 2, 2);
    blit(ship, 14, 6);
    // This copy is over the edge intentionally, to show the clipping.
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
