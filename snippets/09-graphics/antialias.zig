//! title: Antialiasing by Supersampling
//! A hard inside/outside test gives a staircase edge. Ask the same question at
//! sixteen points inside each pixel and the answer becomes a coverage fraction,
//! which is an alpha value.

const std = @import("std");
const canvas = @import("_canvas.zig");

var pixels: [canvas.width * canvas.height]u32 = undefined;

const samples = 4; // 4x4 = 16 tests per pixel

fn blendChannel(src: u8, dst: u8, a: u32) u8 {
    return @intCast((@as(u32, src) * a + @as(u32, dst) * (255 - a) + 127) / 255);
}

/// Coverage in 0..16: how many of the sub-positions inside this pixel fall
/// within the circle. Sub-positions sit at the centres of a 4x4 grid, offset
/// by half a sub-pixel, so the sampling is symmetric about the pixel centre.
///
/// Everything is scaled by `samples * 2` to stay in integers: a sub-position
/// is at an odd multiple of half a sub-pixel, so doubling makes it whole.
fn coverage(x: i32, y: i32, cx: i32, cy: i32, r: i32) u32 {
    const scale = samples * 2;
    const rs = r * scale;
    var hits: u32 = 0;
    var sy: i32 = 0;
    while (sy < samples) : (sy += 1) {
        var sx: i32 = 0;
        while (sx < samples) : (sx += 1) {
            const px = x * scale + 2 * sx + 1;
            const py = y * scale + 2 * sy + 1;
            const dx = px - (cx * scale + samples);
            const dy = py - (cy * scale + samples);
            if (dx * dx + dy * dy <= rs * rs) hits += 1;
        }
    }
    return hits;
}

fn hardCircle(cx: i32, cy: i32, r: i32, color: u32) void {
    var y = cy - r - 1;
    while (y <= cy + r + 1) : (y += 1) {
        var x = cx - r - 1;
        while (x <= cx + r + 1) : (x += 1) {
            const dx = x - cx;
            const dy = y - cy;
            if (dx * dx + dy * dy <= r * r) canvas.putPixel(&pixels, x, y, color);
        }
    }
}

fn smoothCircle(cx: i32, cy: i32, r: i32, color: u32) void {
    var y = cy - r - 1;
    while (y <= cy + r + 1) : (y += 1) {
        var x = cx - r - 1;
        while (x <= cx + r + 1) : (x += 1) {
            const hits = coverage(x, y, cx, cy, r);
            if (hits == 0) continue;
            if (x < 0 or y < 0) continue;
            const ux: usize = @intCast(x);
            const uy: usize = @intCast(y);
            if (ux >= canvas.width or uy >= canvas.height) continue;

            // 16 hits is fully inside; anything less is a partial pixel, and
            // the fraction is exactly the alpha to composite with.
            const alpha = (hits * 255) / (samples * samples);
            const i = uy * canvas.width + ux;
            const s = canvas.channels(color);
            const d = canvas.channels(pixels[i]);
            pixels[i] = canvas.rgb(
                blendChannel(s.r, d.r, alpha),
                blendChannel(s.g, d.g, alpha),
                blendChannel(s.b, d.b, alpha),
            );
        }
    }
}

pub fn main(init: std.process.Init) !void {
    var buf: [8192]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    canvas.fill(&pixels, canvas.rgb(0, 0, 30));

    const ink = canvas.rgb(255, 230, 150);
    hardCircle(16, 16, 12, ink);
    smoothCircle(47, 16, 12, ink);

    try canvas.dump(out, &pixels);

    try out.writeAll("\nleft: hard test. right: 16 samples per pixel.\n");
    try out.writeAll("\ncoverage across the right circle's edge, row y=16:\n");
    var x: i32 = 56;
    while (x <= 61) : (x += 1) {
        const hits = coverage(x, 16, 47, 16, 12);
        try out.print("  x={d}: {d:>2}/16 -> alpha {d:>3}\n", .{ x, hits, (hits * 255) / 16 });
    }

    try out.flush();
}
