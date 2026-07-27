//! The framebuffer shared by the graphics chapters. The leading underscore
//! keeps the build from treating it as a snippet of its own.
//!
//! One `u32` per pixel holding `0x00RRGGBB`, and an ASCII dump so a chapter can
//! show what it drew in a text-only output pane. 64x32 is small enough that one
//! character is one pixel: nothing is resampled, so what you count on screen is
//! what the code wrote.

const std = @import("std");

pub const width: usize = 64;
pub const height: usize = 32;

/// Pack three channels into one pixel. The layout is `0x00RRGGBB`, which on a
/// little-endian machine sits in memory as B, G, R, X: what both X11 and
/// Wayland want from a client buffer.
pub fn rgb(r: u8, g: u8, b: u8) u32 {
    return (@as(u32, r) << 16) | (@as(u32, g) << 8) | @as(u32, b);
}

pub fn channels(color: u32) struct { r: u8, g: u8, b: u8 } {
    return .{
        .r = @truncate(color >> 16),
        .g = @truncate(color >> 8),
        .b = @truncate(color),
    };
}

/// Set one pixel, ignoring coordinates outside the buffer.
///
/// Signed, because a shape computes its pixels by subtracting a centre or a
/// start point and half of those results are negative. Clipping here rather
/// than in each caller is why the shape routines in this section are short.
pub fn putPixel(pixels: []u32, x: i32, y: i32, color: u32) void {
    if (x < 0 or y < 0) return;
    const ux: usize = @intCast(x);
    const uy: usize = @intCast(y);
    if (ux >= width or uy >= height) return;
    pixels[uy * width + ux] = color;
}

pub fn fill(pixels: []u32, color: u32) void {
    @memset(pixels, color);
}

/// A deterministic test picture for the image-processing chapters.
///
/// Three things a filter needs something to bite on: a smooth ramp, so contrast
/// and blur have a gradient to stretch or soften; a hard-edged block, so an edge
/// detector has an edge to find; and two saturated discs, so a colour transform
/// has some chroma to move. Drawing it here rather than in each chapter means
/// all three filter chapters run on the same input and their dumps can be read
/// against each other.
pub fn scene(pixels: []u32) void {
    for (0..height) |y| {
        for (0..width) |x| {
            // A diagonal ramp, so neither a horizontal nor a vertical kernel
            // sees a flat signal.
            const t: u32 = @intCast((x + y * 2) * 255 / (width + height * 2 - 3));
            putPixel(pixels, @intCast(x), @intCast(y), rgb(
                @intCast(10 + t / 5),
                @intCast(10 + t / 5),
                @intCast(40 + t / 3),
            ));
        }
    }

    // Hard edges on all four sides, on purpose.
    for (6..15) |y| {
        for (8..25) |x| {
            putPixel(pixels, @intCast(x), @intCast(y), rgb(255, 220, 60));
        }
    }

    disc(pixels, 44, 10, 7, rgb(230, 40, 40));
    disc(pixels, 50, 23, 6, rgb(40, 220, 90));
}

fn disc(pixels: []u32, cx: i32, cy: i32, r: i32, color: u32) void {
    var y = cy - r;
    while (y <= cy + r) : (y += 1) {
        var x = cx - r;
        while (x <= cx + r) : (x += 1) {
            const dx = x - cx;
            const dy = y - cy;
            if (dx * dx + dy * dy <= r * r) putPixel(pixels, x, y, color);
        }
    }
}

/// Ten characters, dark to light. Ten levels is enough to read a gradient and
/// few enough that a shape's edge stays visible.
const ramp = " .:-=+*#%@";

/// Rec. 601 luma in integers: 0.299 R + 0.587 G + 0.114 B, scaled by 256.
pub fn luma(color: u32) u32 {
    const c = channels(color);
    return (@as(u32, c.r) * 77 + @as(u32, c.g) * 150 + @as(u32, c.b) * 29) >> 8;
}

/// Print the buffer, one character per pixel.
pub fn dump(out: *std.Io.Writer, pixels: []const u32) !void {
    var row: [width]u8 = undefined;
    for (0..height) |y| {
        for (0..width) |x| {
            const level = (luma(pixels[y * width + x]) * (ramp.len - 1)) / 255;
            row[x] = ramp[@intCast(level)];
        }
        // Blanks at the end of a row carry no information, and leaving them in
        // would put trailing whitespace in a checked-in `.expected` file, where
        // any editor that trims on save would break the diff.
        try out.writeAll(std.mem.trimEnd(u8, &row, " "));
        try out.writeByte('\n');
    }
}
