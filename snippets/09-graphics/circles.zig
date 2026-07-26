//! title: Circles Without a Square Root
//! A point is inside a circle when dx*dx + dy*dy <= r*r. Square both sides of
//! the distance test and the sqrt disappears, along with the floats.

const std = @import("std");
const canvas = @import("_canvas.zig");

var pixels: [canvas.width * canvas.height]u32 = undefined;

/// Scans every pixel in the buffer, which is the obvious version and the wrong
/// one: at r = 7 it tests 2048 pixels to fill about 150.
fn fillCircleNaive(cx: i32, cy: i32, r: i32, color: u32) usize {
    var tested: usize = 0;
    for (0..canvas.height) |y| {
        for (0..canvas.width) |x| {
            tested += 1;
            const dx = @as(i32, @intCast(x)) - cx;
            const dy = @as(i32, @intCast(y)) - cy;
            if (dx * dx + dy * dy <= r * r) {
                canvas.putPixel(&pixels, @intCast(x), @intCast(y), color);
            }
        }
    }
    return tested;
}

/// The same circle, looping only over its bounding box. `putPixel` already
/// clips, so a circle hanging off an edge needs no extra handling here.
fn fillCircle(cx: i32, cy: i32, r: i32, color: u32) usize {
    var tested: usize = 0;
    var y = cy - r;
    while (y <= cy + r) : (y += 1) {
        var x = cx - r;
        while (x <= cx + r) : (x += 1) {
            tested += 1;
            const dx = x - cx;
            const dy = y - cy;
            if (dx * dx + dy * dy <= r * r) {
                canvas.putPixel(&pixels, x, y, color);
            }
        }
    }
    return tested;
}

/// An outline is the same test twice: inside the outer radius and outside the
/// inner one. No new algorithm, just a band.
fn strokeCircle(cx: i32, cy: i32, r: i32, thickness: i32, color: u32) void {
    const outer = r * r;
    const inner = (r - thickness) * (r - thickness);
    var y = cy - r;
    while (y <= cy + r) : (y += 1) {
        var x = cx - r;
        while (x <= cx + r) : (x += 1) {
            const dx = x - cx;
            const dy = y - cy;
            const d2 = dx * dx + dy * dy;
            if (d2 <= outer and d2 > inner) {
                canvas.putPixel(&pixels, x, y, color);
            }
        }
    }
}

pub fn main(init: std.process.Init) !void {
    var buf: [8192]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    canvas.fill(&pixels, canvas.rgb(0, 0, 40));

    strokeCircle(20, 16, 13, 2, canvas.rgb(120, 200, 255));
    const naive = fillCircleNaive(20, 16, 7, canvas.rgb(255, 220, 40));
    const boxed = fillCircle(45, 16, 10, canvas.rgb(180, 255, 140));

    // Hangs off three edges at once. Nothing here checks for that; the clip in
    // putPixel does.
    _ = fillCircle(62, 30, 8, canvas.rgb(255, 120, 120));

    try canvas.dump(out, &pixels);

    try out.print("\nfull-buffer scan, r=7:  {d} pixels tested\n", .{naive});
    try out.print("bounding box,     r=10: {d} pixels tested\n", .{boxed});
    try out.print("a circle of r=10 covers about {d} pixels\n", .{
        (314 * 10 * 10) / 100,
    });

    try out.flush();
}
