//! title: Bitmap Text
//! A glyph is a small rectangle of bits, and drawing text is copying them.

const std = @import("std");

const width: usize = 60;
const height: usize = 16;
var pixels: [width * height]u8 = @splat(' ');

/// Each glyph is 7 rows of 5 bits, most significant bit on the left. This is
/// the oldest way to store a font and still the right one for a fixed size:
/// no curves, no hinting, no scaling, just bits you copy.
const glyph_width = 5;
const glyph_height = 7;

const Glyph = [glyph_height]u8;

fn glyphFor(c: u8) ?Glyph {
    return switch (c) {
        'Z' => .{ 0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b10000, 0b11111 },
        'I' => .{ 0b11111, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b11111 },
        'G' => .{ 0b01110, 0b10001, 0b10000, 0b10111, 0b10001, 0b10001, 0b01110 },
        '2' => .{ 0b01110, 0b10001, 0b00001, 0b00010, 0b00100, 0b01000, 0b11111 },
        '0' => .{ 0b01110, 0b10001, 0b10011, 0b10101, 0b11001, 0b10001, 0b01110 },
        '6' => .{ 0b00110, 0b01000, 0b10000, 0b11110, 0b10001, 0b10001, 0b01110 },
        ' ' => .{ 0, 0, 0, 0, 0, 0, 0 },
        else => null,
    };
}

fn putPixel(x: i32, y: i32, ink: u8) void {
    if (x < 0 or y < 0) return;
    const ux: usize = @intCast(x);
    const uy: usize = @intCast(y);
    if (ux >= width or uy >= height) return;
    pixels[uy * width + ux] = ink;
}

/// Draw one glyph. Testing the bit and skipping the zeroes is what makes text
/// draw *over* a background rather than in a box: a glyph has no background of
/// its own, only the pixels it sets.
fn drawGlyph(g: Glyph, x: i32, y: i32, ink: u8) void {
    for (g, 0..) |row, dy| {
        var bit: u3 = 0;
        while (bit < glyph_width) : (bit += 1) {
            const mask = @as(u8, 1) << @intCast(glyph_width - 1 - bit);
            if (row & mask != 0) {
                putPixel(x + @as(i32, bit), y + @as(i32, @intCast(dy)), ink);
            }
        }
    }
}

/// Advance by the glyph width plus one column of spacing. A proportional font
/// stores a per-glyph advance instead, and that single change is most of the
/// difference between a terminal font and a text engine.
fn drawText(text: []const u8, x: i32, y: i32, ink: u8) i32 {
    var pen = x;
    for (text) |c| {
        if (glyphFor(c)) |g| drawGlyph(g, pen, y, ink);
        pen += glyph_width + 1;
    }
    return pen;
}

fn dump(out: *std.Io.Writer) !void {
    for (0..height) |y| {
        try out.print("{s}\n", .{pixels[y * width ..][0..width]});
    }
}

pub fn main(init: std.process.Init) !void {
    var buf: [4096]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    const end = drawText("ZIG 2026", 1, 1, '#');
    _ = drawText("206", 1, 9, '*');

    try dump(out);
    try out.print("\n\"ZIG 2026\" is {d} glyphs and ended at column {d}\n", .{ 8, end });
    try out.print("each glyph is {d}x{d} bits, so the whole font above is {d} bytes\n", .{
        glyph_width, glyph_height, 7 * glyph_height,
    });

    try out.flush();
}
