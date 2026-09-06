# Bitmap Text

> A glyph is a small rectangle of bits, and drawing text is copying them.

Every chapter so far has drawn shapes described by maths: a line from an
equation, a circle from a radius. Text is not like that. There is no formula
for the letter `G`, so the shape has to be stored, and the oldest way to store
it is the simplest one that works.

A glyph is a small rectangle of bits. One bit per pixel, on or off. Drawing a
character means walking those bits and setting a pixel wherever there is a
one.

## The program

```zig
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
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`09-graphics.font`)*

## What just happened

**Each glyph is seven bytes.** Five bits used per row, seven rows, written in
binary so the shape is visible in the source. Look at `Z` in the code and you
can read the letter off the ones.

**The zeroes were skipped, not drawn.** That single `if` is what makes text
composable: a glyph has no background of its own, so it draws *over* whatever
is already there. Filling the zeroes with a background colour would put every
character in an opaque box, which is what happens when you get this wrong and
is immediately obvious.

**The pen advanced by a fixed amount.** Six columns per character, always. That
is a **monospaced** font, and it is why terminal output lines up. A
proportional font stores an advance width per glyph. That one change is most
of the difference between this and a text engine, because now the width of a
string is a sum rather than a multiplication.

**The whole font is 49 bytes.** Seven glyphs at seven bytes each. That is why
this technique survived on machines with kilobytes of memory, and why it is
still what a bootloader or an embedded display uses.

## Check yourself

The glyphs here are 5x7. What has to change to draw them at twice the size?

Nothing about the data, and one line of the drawing loop: write a 2x2 block of
pixels instead of one. That works, and it is why doubled bitmap text has
visibly chunky edges: the information for the in-between pixels was never
there.

Getting a *good* larger size means storing the glyph as outlines, curves
described by control points, and rasterising them at the requested size. That
is what TrueType is. It is also why fonts need *hinting*: at small sizes the
outline rarely lines up with the pixel grid, so the shapes need nudging to
stop a stem landing half in one column and half in the next.

## If you have written C

The font table is `static const unsigned char font[][7]`, indexed by
character, and the classic version indexes it directly with `c - 32` to skip
the control characters. That is fast and is an out-of-bounds read the moment a
byte above 127 arrives, which on any non-ASCII input is immediately. The
version above uses a switch that returns null for anything it does not know.

The other traditional detail is that fonts were stored column-major as often
as row-major, because some displays wanted vertical strips of eight pixels,
which is exactly one byte. That is not a style preference: it is the shape the
hardware read.

Next: sprites, which are the same copy with more than one bit per pixel.
