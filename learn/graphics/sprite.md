# Sprites and Transparency

> Copying a rectangle is easy. Deciding which pixels not to copy is the feature.

A sprite is a small image copied onto a bigger one. The copy is a nested loop
and takes a minute to write.

What makes it a sprite rather than a rectangle is the part that decides which
pixels to leave alone. Without that, every sprite is a box, and a spaceship
drags a square of background around with it.

## The program

```zig
const std = @import("std");

const width: usize = 40;
const height: usize = 14;
var canvas: [width * height]u8 = @splat('.');

/// A sprite is a small image plus a rule for which pixels are see-through.
/// Here the rule is a key colour: one value declared to mean "skip". That is
/// how every 8-bit and 16-bit console did it, because a per-pixel alpha
/// channel costs memory those machines did not have.
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
            // The whole of transparency, in one comparison. Without it a
            // sprite is a rectangle and everything behind its corners is gone.
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

    // Three copies of one sprite. Nothing is duplicated in memory: a sprite is
    // data, and drawing it is a loop, so the second copy costs nothing.
    blit(ship, 2, 2);
    blit(ship, 14, 6);
    // Deliberately over the edge, to show the clipping.
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

**The background shows through the corners.** The checkerboard is visible
inside the sprite's bounding box wherever the sprite's own pixel was the
transparent value. 18 of the 35 pixels were drawn and 17 were skipped, which
is printed so the ratio is visible: nearly half of a sprite is usually
nothing.

**Transparency is one comparison.** A **key colour**: one value declared to
mean "skip". That is how every 8-bit and 16-bit console did it, because a
per-pixel alpha channel costs a byte per pixel that those machines did not
have. It has one famous drawback: the key colour cannot appear in the artwork.
That is why so much sprite work of that era avoided a particular shade of
magenta.

**The third copy was clipped.** Drawn partly off the right edge, and the loop
simply skipped the cells outside the canvas. Clipping is not a feature here,
it is the bounds check being honest.

**Three copies, one sprite.** Nothing was duplicated in memory. A sprite is
data and drawing it is a loop, so the second and third copies cost only the
loop.

## Check yourself

Key-colour transparency is binary: a pixel is drawn or it is not. What does an
alpha channel add, and what does it cost?

Partial transparency, so an edge pixel can be half sprite and half background,
which is the difference between a jagged outline and a smooth one. The cost is
memory, one more byte per pixel, and arithmetic: instead of copying, every
pixel becomes a blend of source and destination weighted by alpha. That is
exactly what the [blending](https://www.ziglang.in/learn/graphics/blending/) chapter builds, and it
is why it comes before this one.

The other cost is order. Opaque sprites can be drawn in any order if they do
not overlap; translucent ones must be drawn back to front, because blending is
not commutative.

## If you have written C

`memcpy` per row is the obvious optimisation and it is only available when
there is no transparency, because `memcpy` cannot skip. That tension is the
whole story of 2D blitting: opaque rectangles are a fast row copy, and
anything with holes in it is a per-pixel loop.

Which is why hardware sprite units existed. The machines that made this
technique famous had silicon that read a sprite and a key colour and
composited during the scan-out. The CPU never touched those pixels at all.
When people say a 1985 console did something a faster PC could not, this is
usually what they mean.

Next: a scene graph, which is how you move a lot of these at once.
