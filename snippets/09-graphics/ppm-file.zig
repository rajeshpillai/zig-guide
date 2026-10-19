//! title: Writing the PPM to Disk
//! The same bytes, but through the filesystem API. Two calls: the header, then
//! the pixels.

const std = @import("std");

const width: usize = 640;
const height: usize = 480;

// Three bytes per pixel, 921,600 bytes in total. Global, not on the stack.
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

    // The circle comes second, thus it is on top. This code has no depth buffer
    // and no transparency. A later write replaces an earlier write.
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

    // The program writes a real file, reads it again and deletes it. Thus the
    // example leaves no file on the computer that ran it.
    defer dir.deleteFile(io, "output.ppm") catch {};

    // A createFile handle is write-only by default. With `.read = true`, the
    // check at the end can read through this handle and not open the file again.
    const file = try dir.createFile(io, "output.ppm", .{ .read = true });
    defer file.close(io);

    var header_buf: [32]u8 = undefined;
    const header = try std.mem.print(&header_buf, "P6\n{d} {d}\n255\n", .{ width, height });

    try file.writeStreamingAll(io, header);
    try file.writeStreamingAll(io, &pixels);

    // To know that the two writes above went in the correct order, read the
    // header again. An image viewer shows the problem later. This check makes
    // the build fail now.
    var check: [15]u8 = undefined;
    _ = try file.readPositionalAll(io, &check, 0);

    try out.writeAll("header read back:\n");
    try out.writeAll(check[0..header.len]);
    try out.print("bytes on disk: {d}\n", .{header.len + pixels.len});
    try out.flush();
}

// This program runs in wasm. The runner gives it an empty working directory:
// a temporary directory in CI, and a directory in memory in your browser. In
// both, the program really writes the file and reads it again.
