//! title: A Framebuffer Is an Array
//! Row-major, top-left origin, one 32-bit pixel per cell. All other chapters
//! in this section write into a buffer with exactly this shape.

const std = @import("std");

const width: usize = 64;
const height: usize = 32;

// Global, not local. At 64x32 the array fits in all stacks. At 640x480 the
// same array is 1.2 MB. The default thread stack is 8 MB on Linux, 1 MB on
// Windows, and much less on some embedded targets. Thus a picture on the stack
// can overflow the stack on a different platform. Make the picture global, or
// allocate it on the heap.
//
// `undefined` is safe only because `drawGradient` below writes each cell.
// A partial scene must start from a known fill. If it does not, the image
// contains the old data that was in memory.
var pixels: [width * height]u32 = undefined;

/// Pack three channels into `0x00RRGGBB`.
fn rgb(r: u8, g: u8, b: u8) u32 {
    return (@as(u32, r) << 16) | (@as(u32, g) << 8) | @as(u32, b);
}

/// Row-major: pixel (x, y) is at `y * width + x`. The rows are contiguous, one
/// after the other, and y = 0 is the *top* row.
fn index(x: usize, y: usize) usize {
    return y * width + x;
}

// The coordinates are signed because callers get them by subtraction. Half of
// these results are negative. In `usize`, a negative result underflows to a
// very large number. In Debug the result is a panic. In the other modes the
// result is a wrong answer.
fn putPixel(x: i32, y: i32, color: u32) void {
    if (x < 0 or y < 0) return;
    const ux: usize = @intCast(x);
    const uy: usize = @intCast(y);
    if (ux >= width or uy >= height) return;
    pixels[index(ux, uy)] = color;
}

fn drawGradient() void {
    for (0..height) |y| {
        for (0..width) |x| {
            // Multiply before you divide. `(x / (width - 1)) * 255` is zero in
            // all columns but the last, because integer division truncates.
            // The divisor is `width - 1`, not `width`, thus the last column
            // gets exactly 255.
            const r: u8 = @intCast((x * 255) / (width - 1));
            const g: u8 = @intCast((y * 255) / (height - 1));
            putPixel(@intCast(x), @intCast(y), rgb(r, g, 80));
        }
    }
}

// Ten characters, from dark to light, one per pixel. The section uses them to
// show a picture in a pane that has only text. A real program gives the same
// buffer to a file or a display server.
const ramp = " .:-=+*#%@";

fn dump(out: *std.Io.Writer) !void {
    var row: [width]u8 = undefined;
    for (0..height) |y| {
        for (0..width) |x| {
            const p = pixels[index(x, y)];
            const r: u32 = (p >> 16) & 0xFF;
            const g: u32 = (p >> 8) & 0xFF;
            const b: u32 = p & 0xFF;
            // Rec. 601 luma in integers, scaled by 256.
            const level = ((r * 77 + g * 150 + b * 29) >> 8) * (ramp.len - 1) / 255;
            row[x] = ramp[@intCast(level)];
        }
        try out.writeAll(std.mem.trimEnd(u8, &row, " "));
        try out.writeByte('\n');
    }
}

pub fn main(init: std.process.Init) !void {
    var buf: [8192]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    drawGradient();

    try out.print("buffer: {d}x{d} pixels, {d} bytes\n", .{
        width, height, @sizeOf(@TypeOf(pixels)),
    });
    try out.print("(0, 0)   -> index {d}\n", .{index(0, 0)});
    try out.print("(1, 0)   -> index {d}\n", .{index(1, 0)});
    try out.print("(0, 1)   -> index {d}  (one whole row later)\n", .{index(0, 1)});
    try out.print("(63, 31) -> index {d}  = 0x{X:0>6}\n\n", .{
        index(63, 31), pixels[index(63, 31)],
    });

    try dump(out);
    try out.flush();
}
