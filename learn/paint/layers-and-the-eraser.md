# Layers and the Eraser

> Layers are transparent pixel arrays on white paper. Store them premultiplied, and the eraser becomes one multiplication.

A **layer** is a sheet of clear plastic that you can paint on.

Put two sheets on white paper. If you paint on the top sheet, the bottom sheet does not change. If you clean the top sheet, you can see the bottom sheet again.

The engine has two of these layers, on white paper.

## A layer is an array

A layer has one pixel for each position, row by row. Thus it has `width * height` pixels.

Each pixel has four bytes: red, green, blue, and alpha. Alpha is the coverage of the pixel. 0 is clear plastic, and 255 is solid paint.

```zig
/// `extern` fixes the field order in memory. A row of these values has the
/// R, G, B, A bytes in the order that a browser canvas expects. Thus the
/// display needs no conversion.
pub const Rgba = extern struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,

    pub const transparent: Rgba = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
    pub const white: Rgba = .{ .r = 255, .g = 255, .b = 255, .a = 255 };

    pub fn opaqueRgb(c: [3]u8) Rgba {
        return .{ .r = c[0], .g = c[1], .b = c[2], .a = 255 };
    }
};
```

*Quoted from the source: `Rgba` from `examples/paint/src/engine/pixel.zig`.*

`extern` fixes the order of the fields in memory: R, G, B, A, one byte each. A browser canvas expects that order. Thus the code can copy the screen buffer to a canvas with no conversion. With a plain Zig `struct`, the compiler can change the order of the fields.

Two layers at 640 by 400 hold 2 × 640 × 400 × 4 = 2,048,000 bytes. The program does not store the white paper. The white paper is the start value of the drawing.

## Draw the stack

To get the colour of one screen pixel, start with white paper. Then put each visible layer on it, from the bottom up:

```zig
    /// One screen pixel: white paper, then each visible layer from the
    /// bottom up.
    fn composite(d: *const Document, x: u32, y: u32) Rgba {
        const i = @as(usize, y) * d.width + x;
        var out: Rgba = .white;
        for (d.layers, d.visible, 0..) |layer, visible, li| {
            if (!visible) continue;
            var p = layer[i];
            if (d.stroke) |active| {
                if (active.layer == li) p = applyStroke(active, p, d.mask.coverage[i], d.mask.color[i]);
            }
            out = pixel.over(p, out);
        }
        return out;
    }
```

*Quoted from the source: `composite` from `examples/paint/src/engine/document.zig`.*

The order is important. A solid pixel on the top layer hides the bottom layer. If you change the order of the layers, the result is the opposite.

The engine does this only for the rectangle that changed. A dab touches some hundreds of pixels. Thus the engine composites only those pixels again.

## Premultiplied alpha

There are two ways to store a red pixel with half coverage:

- **Straight** alpha stores the colour and the coverage separately: (255, 0, 0, 128). This is full red with half coverage.
- **Premultiplied** alpha stores the colour after a multiplication by the coverage: (128, 0, 0, 128).

The layers in this program are premultiplied, because of the eraser.

## The eraser

On white paper, white paint and the eraser look the same.

Over another layer, they are different. White paint covers the layer below it. The eraser removes paint from its own layer, thus you can see the layer below.

To erase means "keep less of this pixel". With premultiplied values, that is the same multiplication on all four channels:

```zig
/// Remove `amount` (0 to 65535) of `dst`. White paint and the eraser look
/// the same on white paper. Over another layer, white covers it and the
/// eraser reveals it.
pub fn erase(dst: Rgba, amount: u32) Rgba {
    const keep = full - amount;
    return .{
        .r = @intCast(scale(dst.r, keep)),
        .g = @intCast(scale(dst.g, keep)),
        .b = @intCast(scale(dst.b, keep)),
        .a = @intCast(scale(dst.a, keep)),
    };
}
```

*Quoted from the source: `erase` from `examples/paint/src/engine/pixel.zig`.*

If you erase a pixel fully, each channel becomes 0. No colour remains.

With straight alpha, a red pixel after a full erase is (255, 0, 0, 0). You cannot see it, but it is still red. That hidden red is a known cause of bugs. If you scale or blur the layer, the code averages the hidden red with the pixels near it. Then the red is visible again as a red edge along each erased area.

## Paint and combine

To paint, the code puts a colour over a pixel with a given coverage:

```zig
/// Lay `color` over `dst` with coverage `amount` (0 to 65535).
pub fn paint(dst: Rgba, color: [3]u8, amount: u32) Rgba {
    const keep = full - amount;
    return .{
        .r = @intCast(scale(color[0], amount) + scale(dst.r, keep)),
        .g = @intCast(scale(color[1], amount) + scale(dst.g, keep)),
        .b = @intCast(scale(color[2], amount) + scale(dst.b, keep)),
        .a = @intCast(scale(255, amount) + scale(dst.a, keep)),
    };
}
```

*Quoted from the source: `paint` from `examples/paint/src/engine/pixel.zig`.*

To combine two layers, the code uses the "over" operator from the [Alpha Blending](https://www.ziglang.in/learn/graphics/blending/) chapter, without its first multiplication. The colour in `top` is already multiplied by its alpha:

```zig
/// `top` over `below`, both premultiplied. This is the operator from the
/// Alpha Blending chapter, without its multiply: the colour in `top` is
/// already scaled by its alpha.
pub fn over(top: Rgba, below: Rgba) Rgba {
    const keep = (255 - @as(u32, top.a)) * 257; // 255 * 257 = 65535
    return .{
        .r = @intCast(top.r + scale(below.r, keep)),
        .g = @intCast(top.g + scale(below.g, keep)),
        .b = @intCast(top.b + scale(below.b, keep)),
        .a = @intCast(top.a + scale(below.a, keep)),
    };
}
```

*Quoted from the source: `over` from `examples/paint/src/engine/pixel.zig`.*

All of this is integer arithmetic, with rounding to the nearest whole number. Two roundings in one sum can cause a problem: if two halves both round up, the total is one too large. In a `u8`, that total is 256, which does not fit. Then `@intCast` stops a safe build.

That cannot occur here, but the reason is not obvious. Thus a test examines each of the 65,536 coverage values:

```zig
test "paint never overflows a byte, at any coverage" {
    // The sum of the two rounded parts is 255 or less. The sum of their
    // exact values is 255. Both parts can round up only if both end in
    // exactly .5, and `amount / 257` never does. This test examines the
    // claim. It does not trust it.
    var amount: u32 = 0;
    while (amount <= full) : (amount += 1) {
        const out = paint(.white, .{ 255, 255, 255 }, amount);
        try std.testing.expectEqual(@as(u8, 255), out.a);
        try std.testing.expectEqual(@as(u8, 255), out.r);
    }
}
```

*Quoted from the source: `paint never overflows a byte, at any coverage` from `examples/paint/src/engine/pixel.zig`.*

## Blend in bytes, not in light

The [Linear Light](https://www.ziglang.in/learn/graphics/linear-light/) chapter shows that a mix of stored bytes is not the same as a mix of light.

This engine mixes bytes. A browser canvas does the same, and so do most 8-bit paint programs.

That is a decision. Each layer stays at 4 bytes for each pixel, and the colours do what users of other paint programs expect. A program that mixes in linear light needs 8 bytes for each pixel to keep the dark tones. That doubles each number in this chapter.

## Checks

This test makes sure that a red pixel with half coverage is premultiplied:

```zig
test "half red on an empty layer is stored premultiplied" {
    const p = paint(.transparent, .{ 255, 0, 0 }, full / 2 + 1);
    try std.testing.expectEqual(Rgba{ .r = 128, .g = 0, .b = 0, .a = 128 }, p);
}
```

*Quoted from the source: `half red on an empty layer is stored premultiplied` from `examples/paint/src/engine/pixel.zig`.*

This test uses the eraser and white paint on the top layer, over a red bottom layer:

```zig
test "the eraser reveals the layer below, white paint covers it" {
    var d = try newDoc();
    defer d.deinit();
    const red: [3]u8 = .{ 220, 0, 0 };
    // Bottom layer: solid red everywhere.
    _ = try d.fillAt(0, 0, red);
    // Top layer: solid blue everywhere.
    _ = d.setActiveLayer(1);
    _ = try d.fillAt(0, 0, .{ 0, 0, 220 });

    const hard: Brush = .{ .radius = 5, .hardness = 1, .flow = 1, .color = .{ 255, 255, 255 } };
    d.beginStroke(hard, .eraser, .{ .x = 16, .y = 24 });
    d.endStroke();
    d.beginStroke(hard, .brush, .{ .x = 48, .y = 24 });
    d.endStroke();
    _ = d.render();

    try testing.expectEqual(Rgba.opaqueRgb(red), d.display[24 * 64 + 16]); // erased: red shows
    try testing.expectEqual(Rgba.white, d.display[24 * 64 + 48]); // white paint
}
```

*Quoted from the source: `the eraser reveals the layer below, white paint covers it` from `examples/paint/src/engine/document.zig`.*

## Explain before you read the answer

The top layer has a solid blue pixel, (0, 0, 220, 255). You erase it at 50%.

What does the pixel store? What does the screen show over a red bottom layer?

The pixel stores (0, 0, 110, 127). Each channel is half of the channel in (0, 0, 220, 255), after rounding.

On the screen, the result is half of the blue over the red: (128, 0, 110), a purple.

Red paint at 50% over the blue shows the same purple. The difference occurs later. If you change the bottom layer to green, the erased pixel shows blue over green. The painted pixel still shows the red that you painted.
