//! title: Alpha Blending
//! To write over a pixel is the painter's algorithm. When the shape on top
//! is not opaque, use blending instead.

const std = @import("std");
const canvas = @import("_canvas.zig");

var pixels: [canvas.width * canvas.height]u32 = undefined;

/// The source-over operator on one channel:
///
///     out = (src * a + dst * (255 - a)) / 255
///
/// The `+ 127` rounds to the nearest value. Without it, the division removes
/// the fraction. A division by 256 with a shift looks faster. But at a = 255
/// the shift gives 254. Thus blending code that uses the shift cannot make
/// pure white.
fn blendChannel(src: u8, dst: u8, a: u8) u8 {
    const s = @as(u32, src) * @as(u32, a);
    const d = @as(u32, dst) * (255 - @as(u32, a));
    return @intCast((s + d + 127) / 255);
}

fn blend(src: u32, dst: u32, a: u8) u32 {
    const s = canvas.channels(src);
    const d = canvas.channels(dst);
    return canvas.rgb(
        blendChannel(s.r, d.r, a),
        blendChannel(s.g, d.g, a),
        blendChannel(s.b, d.b, a),
    );
}

/// Read, blend, then write the result. The difference from `putPixel` is that
/// the destination is now an input. A later draw does not erase an earlier
/// draw, and the order of the draws changes the result.
fn blendPixel(x: i32, y: i32, color: u32, a: u8) void {
    if (x < 0 or y < 0) return;
    const ux: usize = @intCast(x);
    const uy: usize = @intCast(y);
    if (ux >= canvas.width or uy >= canvas.height) return;

    const i = uy * canvas.width + ux;
    pixels[i] = blend(color, pixels[i], a);
}

fn blendCircle(cx: i32, cy: i32, r: i32, color: u32, a: u8) void {
    var y = cy - r;
    while (y <= cy + r) : (y += 1) {
        var x = cx - r;
        while (x <= cx + r) : (x += 1) {
            const dx = x - cx;
            const dy = y - cy;
            if (dx * dx + dy * dy <= r * r) blendPixel(x, y, color, a);
        }
    }
}

pub fn main(init: std.process.Init) !void {
    var buf: [8192]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    for (0..canvas.height) |y| {
        for (0..canvas.width) |x| {
            const g: u8 = @intCast((x * 90) / (canvas.width - 1));
            canvas.putPixel(&pixels, @intCast(x), @intCast(y), canvas.rgb(20, g, 60));
        }
    }

    // Three discs at 60% opacity. Where two discs overlap, the background
    // shows through both discs. The overlap is brighter than each disc alone.
    blendCircle(24, 13, 11, canvas.rgb(255, 80, 80), 153);
    blendCircle(40, 13, 11, canvas.rgb(80, 255, 120), 153);
    blendCircle(32, 24, 11, canvas.rgb(120, 160, 255), 153);

    try canvas.dump(out, &pixels);

    const white = canvas.rgb(255, 255, 255);
    const black = canvas.rgb(0, 0, 0);

    try out.writeAll("\nwhite over black:\n");
    for ([_]u8{ 0, 64, 128, 192, 255 }) |a| {
        const result = canvas.channels(blend(white, black, a));
        try out.print("  a={d:>3} -> {d:>3} (shift-by-256 would give {d:>3})\n", .{
            a, result.r, (@as(u32, 255) * a) >> 8,
        });
    }

    // Blending is not commutative. Half of red on top of blue is not equal to
    // half of blue on top of red. Thus the draw order is still important.
    const red = canvas.rgb(255, 0, 0);
    const blue = canvas.rgb(0, 0, 255);
    const r_over_b = canvas.channels(blend(red, blue, 64));
    const b_over_r = canvas.channels(blend(blue, red, 64));
    try out.print("\nred over blue  at a=64: {d} {d} {d}\n", .{ r_over_b.r, r_over_b.g, r_over_b.b });
    try out.print("blue over red  at a=64: {d} {d} {d}\n", .{ b_over_r.r, b_over_r.g, b_over_r.b });

    try out.flush();
}
