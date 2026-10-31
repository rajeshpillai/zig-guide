# Sprites and Transparency

> A copy of a rectangle is easy. The important feature is the decision about which pixels not to copy.

A sprite is a small image that a program copies onto a larger image. The copy
is a nested loop, and you can write it in a minute.

A sprite is different from a rectangle because of one part: the part that
decides which pixels to skip. Without that part, each sprite is a box. Then a
spaceship moves a square of background with it.

## The program

```zig
const std = @import("std");

const width: usize = 40;
const height: usize = 14;
var canvas: [width * height]u8 = @splat('.');

/// A sprite is a small image and a rule for the pixels that are transparent.
/// Here the rule is a key colour: one value that means "skip". The 8-bit and
/// 16-bit consoles used this method, because a per-pixel alpha channel costs
/// memory that those machines did not have.
const Sprite = struct {
    w: usize,
    h: usize,
    pixels: []const u8,
    transparent: u8,
};

const ship = Sprite{
    .w = 7,
    .h = 5,
    .transparent = ' ',
    .pixels = "   A   " ++
        "  AAA  " ++
        " AABAA " ++
        "AAAAAAA" ++
        " A   A ",
};

fn blit(sprite: Sprite, x: i32, y: i32) void {
    for (0..sprite.h) |sy| {
        for (0..sprite.w) |sx| {
            const value = sprite.pixels[sy * sprite.w + sx];
            // All of transparency is this one comparison. Without it, a
            // sprite is a rectangle, and the sprite hides all of the pixels
            // behind its corners.
            if (value == sprite.transparent) continue;

            const dx = x + @as(i32, @intCast(sx));
            const dy = y + @as(i32, @intCast(sy));
            if (dx < 0 or dy < 0) continue;
            const ux: usize = @intCast(dx);
            const uy: usize = @intCast(dy);
            if (ux >= width or uy >= height) continue;

            canvas[uy * width + ux] = value;
        }
    }
}

fn fillBackground() void {
    for (0..height) |y| {
        for (0..width) |x| {
            canvas[y * width + x] = if ((x / 4 + y / 2) % 2 == 0) '.' else ',';
        }
    }
}

fn dump(out: *std.Io.Writer) !void {
    for (0..height) |y| try out.print("{s}\n", .{canvas[y * width ..][0..width]});
}

pub fn main(init: std.process.Init) !void {
    var buf: [4096]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    fillBackground();

    // Three copies of one sprite. The program does not copy the data in
    // memory. A sprite is data, and a loop draws it. Thus the second copy
    // costs no memory.
    blit(ship, 2, 2);
    blit(ship, 14, 6);
    // This copy is over the edge intentionally, to show the clipping.
    blit(ship, 36, 9);

    try dump(out);

    try out.print("\nthe sprite is {d}x{d} = {d} bytes\n", .{ ship.w, ship.h, ship.w * ship.h });
    var opaque_count: usize = 0;
    for (ship.pixels) |p| {
        if (p != ship.transparent) opaque_count += 1;
    }
    try out.print("{d} of those pixels are drawn, {d} are skipped\n", .{
        opaque_count,
        ship.w * ship.h - opaque_count,
    });

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`09-graphics.sprite`)*

## What just happened

**The background shows through the corners.** Inside the bounding box of the
sprite, you can see the checkerboard at each pixel where the sprite has the
transparent value. The program drew 18 of the 35 pixels and skipped 17. The
program prints these counts, so you can see the ratio: almost half of a sprite
is usually empty.

**Transparency is one comparison.** The program uses a **key colour**: one
value that means "skip". Each 8-bit and 16-bit console used this method. The
reason is that a per-pixel alpha channel costs one byte per pixel, and those
machines did not have that memory.

The method has one well-known disadvantage: the artwork cannot use the key
colour. For this reason, much sprite art of that time did not use one specific
shade of magenta.

**The program clipped the third copy.** The program drew the third copy
partly off the right edge, and the loop skipped the cells outside the canvas.
No extra code does the clipping. The clipping comes from the bounds check.

**The program stores the sprite one time and draws it three times.** The
program does not make a copy of the sprite data in memory. A sprite is data, and a loop draws it. Thus the second
and third copies cost only the loop.

## Check yourself

Key-colour transparency is binary: the program draws a pixel or it does not.
What does an alpha channel add, and what is its cost?

An alpha channel adds partial transparency. Thus an edge pixel can be half
sprite and half background. This is the difference between a jagged outline
and a smooth outline.

The cost has two parts:

- Memory: one more byte per pixel.
- Arithmetic: the program does not only copy. Each pixel becomes a blend of
  the source and the destination, with alpha as the weight.

The [blending](https://www.ziglang.in/learn/graphics/blending/) chapter makes exactly that blend.
For this reason, the blending chapter comes before this chapter.

The other cost is order. If opaque sprites do not overlap, you can draw them
in any order. You must draw translucent sprites from back to front, because
blending is not commutative.

## If you know C

The usual optimisation is a `memcpy` for each row. You can use it only when
there is no transparency, because `memcpy` cannot skip. This trade-off
controls all of 2D blitting. An opaque rectangle is a fast copy of rows. An
image with holes is a loop over each pixel.

Hardware sprite units existed for this reason. The machines that made this
method famous had silicon that read a sprite and a key colour. The silicon
composited the sprite during the scan-out, and the CPU did not touch those
pixels. Sometimes people say that a 1985 console did something that a faster
PC could not do. Usually, they mean this hardware.

Next: a scene graph, which moves many sprites at the same time.
