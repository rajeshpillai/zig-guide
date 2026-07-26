//! title: A PPM in Memory
//! Assemble a binary P6 image byte by byte, then parse it straight back. PPM
//! is the shortest path from a buffer you filled in yourself to a file an
//! image viewer will open, and it needs no library at all.

const std = @import("std");
const canvas = @import("_canvas.zig");

var pixels: [canvas.width * canvas.height]u32 = undefined;

// The header is at most a few dozen bytes; the body is three bytes per pixel.
var file_bytes: [64 + canvas.width * canvas.height * 3]u8 = undefined;

fn drawScene() void {
    for (0..canvas.height) |y| {
        for (0..canvas.width) |x| {
            const r: u8 = @intCast((x * 255) / (canvas.width - 1));
            const g: u8 = @intCast((y * 255) / (canvas.height - 1));
            canvas.putPixel(&pixels, @intCast(x), @intCast(y), canvas.rgb(r, g, 80));
        }
    }
}

/// Write header then body, and return the slice actually used.
///
/// The header is formatted from the same constants that size the buffer.
/// Hardcoding "P6\n64 32\n255\n" works right up until someone changes one of
/// them, at which point the header and the data disagree and the image tears
/// diagonally, with no error reported anywhere.
fn encodeP6(out: []u8) ![]const u8 {
    const header = try std.fmt.bufPrint(out, "P6\n{d} {d}\n255\n", .{
        canvas.width, canvas.height,
    });

    var n = header.len;
    for (pixels) |p| {
        const c = canvas.channels(p);
        out[n + 0] = c.r;
        out[n + 1] = c.g;
        out[n + 2] = c.b;
        n += 3;
    }
    return out[0..n];
}

const Image = struct { w: usize, h: usize, data: []const u8 };

/// Enough of a reader for files this code writes. It does not handle `#`
/// comments, which a general parser must.
fn decodeP6(bytes: []const u8) !Image {
    if (!std.mem.startsWith(u8, bytes, "P6")) return error.NotP6;

    var it = std.mem.tokenizeAny(u8, bytes[2..], " \t\r\n");
    const w = try std.fmt.parseInt(usize, it.next() orelse return error.Truncated, 10);
    const h = try std.fmt.parseInt(usize, it.next() orelse return error.Truncated, 10);
    const maxval = try std.fmt.parseInt(usize, it.next() orelse return error.Truncated, 10);
    if (maxval != 255) return error.UnsupportedMaxval;

    // Exactly one whitespace byte follows maxval, and everything after it is
    // pixel data. The tokenizer stops before that byte, hence the `+ 1`.
    const data_start = 2 + it.index + 1;
    if (data_start + w * h * 3 > bytes.len) return error.Truncated;
    return .{ .w = w, .h = h, .data = bytes[data_start..] };
}

pub fn main(init: std.process.Init) !void {
    var buf: [4096]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    drawScene();
    const file = try encodeP6(&file_bytes);

    try out.print("total bytes: {d}\n", .{file.len});
    try out.print("header:      {d} bytes, body {d}x{d}x3 = {d}\n", .{
        file.len - canvas.width * canvas.height * 3,
        canvas.width,
        canvas.height,
        canvas.width * canvas.height * 3,
    });

    try out.writeAll("first 16:   ");
    for (file[0..16]) |b| try out.print(" {X:0>2}", .{b});
    try out.writeAll("\n");
    try out.writeAll("as text:     ");
    for (file[0..16]) |b| {
        try out.writeByte(if (b >= 0x20 and b < 0x7F) b else '.');
    }
    try out.writeAll("\n\n");

    const decoded = try decodeP6(file);
    try out.print("decoded:     {d}x{d}, {d} bytes of pixel data\n", .{
        decoded.w, decoded.h, decoded.w * decoded.h * 3,
    });
    try out.print("pixel (0,0): {d} {d} {d}\n", .{
        decoded.data[0], decoded.data[1], decoded.data[2],
    });
    const last = (canvas.width * canvas.height - 1) * 3;
    try out.print("last pixel:  {d} {d} {d}\n", .{
        decoded.data[last], decoded.data[last + 1], decoded.data[last + 2],
    });

    // One extra newline after maxval would shift every pixel by a byte, and no
    // parser can detect it: 0x0A is a legal pixel value.
    const shifted = decodeP6("P6\n2 1\n255\n\n\x01\x02\x03\x04\x05\x06") catch unreachable;
    try out.print("shifted by one: first pixel reads {d} {d} {d}\n", .{
        shifted.data[0], shifted.data[1], shifted.data[2],
    });

    try out.flush();
}
