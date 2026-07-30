//! title: Writing the PPM to Disk
//! native
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

    var buf_out: [128]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &buf_out);
    const out = &stdout.interface;

    drawScene();

    var dir = std.Io.Dir.cwd();

    // Written for real, then read back and removed, so the example leaves
    // nothing behind on the machine that ran it.
    defer dir.deleteFile(io, "output.ppm") catch {};

    // `.read = true` only so the check at the end can reopen nothing: a
    // createFile handle is write-only by default.
    const file = try dir.createFile(io, "output.ppm", .{ .read = true });
    defer file.close(io);

    var header_buf: [32]u8 = undefined;
    const header = try std.mem.print(&header_buf, "P6\n{d} {d}\n255\n", .{ width, height });

    try file.writeStreamingAll(io, header);
    try file.writeStreamingAll(io, &pixels);

    // Reading the header back is the only way to know the two writes above
    // landed in the right order. A viewer would tell you eventually; this
    // tells the build.
    var check: [15]u8 = undefined;
    _ = try file.readPositionalAll(io, &check, 0);

    try out.writeAll("header read back:\n");
    try out.writeAll(check[0..header.len]);
    try out.print("bytes on disk: {d}\n", .{header.len + pixels.len});
    try out.flush();
}

// Marked `//! native`: CI builds this for the host and runs it against a real
// filesystem, so the file really is written and read back. The browser cannot
// run it, because the WASI sandbox has no preopened directories.
