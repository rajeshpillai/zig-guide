# Bitmap Text

> A glyph is a small rectangle of bits. To draw text, copy those bits.

The earlier chapters drew shapes from maths: a line from an equation, a circle
from a radius. Text is different. No formula gives the letter `G`, so the
program must store the shape. The oldest method to store the shape is the
simplest method that works.

A glyph is a small rectangle of bits, with one bit per pixel, on or off. To
draw a character, the program reads each bit. Where the bit is a one, the
program sets a pixel.

## The program

```zig
const std = @import("std");

const width: usize = 60;
const height: usize = 16;
var pixels: [width * height]u8 = @splat(' ');

/// Each glyph is 7 rows of 5 bits, with the most significant bit on the left.
/// This is the oldest method to store a font, and it is still correct for a
/// fixed size. It needs no curves, hinting or scaling. To draw a glyph, the
/// program copies bits.
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

/// Draw one glyph. The function tests each bit and skips the zeroes. Thus text
/// draws *over* a background and not in a box. A glyph has no background of
/// its own. It has only the pixels that it sets.
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

/// Move the pen by the glyph width plus one column of spacing. A proportional
/// font stores an advance for each glyph. That one change is most of the
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

**Each glyph is seven bytes.** Each row uses five bits, and there are seven
rows. The source writes the rows in binary, so you can see the shape. Look at
`Z` in the code, and you can read the letter from the ones.

**The program skipped the zeroes. It did not draw them.** That one `if` lets
text compose with other drawings. A glyph has no background of its own, so it
draws *over* the pixels that are already there. If the program fills the
zeroes with a background colour, each character is in an opaque box. This
mistake is immediately visible.

**The pen moved by a fixed amount.** The step is always six columns per
character. A font of this type is a **monospaced** font, and for this reason
terminal output aligns in columns. A proportional font stores an advance width
for each glyph. That one change is most of the difference between this program
and a text engine. With that change, the width of a string is a sum and not a
multiplication.

**The full font is 49 bytes.** There are seven glyphs at seven bytes each. For
this reason, machines with only kilobytes of memory used this method. A
bootloader or an embedded display still uses this method.

## Check yourself

The glyphs here are 5x7. What must change to draw them at twice the size?

The data does not change, and one line of the loop changes: write a 2x2 block
of pixels and not one pixel. This method works. It is also the reason that
doubled bitmap text has visibly blocky edges. The data never had the
information for the pixels between.

A *good* larger size needs a different glyph format. Store the glyph as
outlines, which are curves that control points define. Then rasterise the
outlines at the requested size. TrueType uses this method.

Outlines are also the reason that fonts need *hinting*. At small sizes, the
outline rarely aligns with the pixel grid. Thus the shapes need small
adjustments. Without the adjustments, a stem can be half in one column and half
in the next column.

## If you know C

The font table is `static const unsigned char font[][7]`, with the character as
the index. The classic version uses `c - 32` as the index directly, to skip the
control characters. This method is fast. But it is an out-of-bounds read when
a byte above 127 arrives, and all non-ASCII input contains such bytes. The
version above uses a switch that returns null for each character that it does
not know.

The other traditional detail is the storage order. Fonts were column-major as
frequently as they were row-major. Some displays used vertical strips of
eight pixels, and eight pixels are exactly one byte. The storage order followed
the order that the hardware read.

Next: sprites, which use the same copy with more than one bit per pixel.
