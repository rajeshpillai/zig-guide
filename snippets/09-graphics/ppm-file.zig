//! title: Writing the PPM to Disk
//! norun
//! The same bytes, but through the filesystem API. Two calls: the header, then
//! the pixels.

const std = @import("std");

const width: usize = 640;
const height: usize = 480;

// Three bytes per pixel, 921,600 of them. Global, not on the stack.
var pixels: [width * height * 3]u8 = undefined;

fn putPixel(x: usize, y: usize, r: u8, g: u8, b: u8) void {
    if (x >= width or y >= height) return;
    const i = (y * width + x) * 3;
    pixels[i + 0] = r;
    pixels[i + 1] = g;
    pixels[i + 2] = b;
}

fn drawScene() void {
    for (0..height) |y| {
        for (0..width) |x| {
            const r: u8 = @intCast((x * 255) / (width - 1));
            const g: u8 = @intCast((y * 255) / (height - 1));
            putPixel(x, y, r, g, 80);
        }
    }

    // Painted second, so it lands on top. There is no depth buffer and no
    // transparency here: a later write simply overwrites an earlier one.
    const cx: i32 = @intCast(width / 2);
    const cy: i32 = @intCast(height / 2);
    const radius: i32 = 100;
    var y: i32 = cy - radius;
    while (y <= cy + radius) : (y += 1) {
        var x: i32 = cx - radius;
        while (x <= cx + radius) : (x += 1) {
            const dx = x - cx;
            const dy = y - cy;
            if (dx * dx + dy * dy <= radius * radius) {
                putPixel(@intCast(x), @intCast(y), 255, 220, 40);
            }
        }
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    drawScene();

    const file = try std.Io.Dir.cwd().createFile(io, "output.ppm", .{});
    defer file.close(io);

    var header_buf: [32]u8 = undefined;
    const header = try std.fmt.bufPrint(&header_buf, "P6\n{d} {d}\n255\n", .{ width, height });

    try file.writeStreamingAll(io, header);
    try file.writeStreamingAll(io, &pixels);
}

// Marked `//! norun`: the browser WASI sandbox has no preopened directories,
// so there is nowhere to create the file. It is still compiled on every CI
// run, which is what catches a filesystem API change.
