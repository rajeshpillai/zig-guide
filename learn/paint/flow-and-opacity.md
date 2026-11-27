# Flow and Opacity

> Dabs overlap. Put the coverage of a stroke in its own buffer and apply its opacity at the end. Then a stroke at 50% stays at 50% where it crosses itself.

A brush has two settings, and both seem to mean "how much paint":

- **Flow** is the quantity that one dab adds.
- **Opacity** is the maximum coverage of the full stroke.

The two settings are different. The difference is visible when dabs overlap. Each stroke is a set of dabs that overlap, thus the difference is visible in all strokes.

## The problem

For example, the code draws each dab directly onto the layer at 50%.

Two dabs overlap at a pixel. The first dab covers 50% of the pixel. The second dab covers half of the remainder, thus the pixel has 75% coverage. Along a slow stroke, ten dabs overlap, and the pixel is almost at 100%.

Thus a stroke "at 50%" is solid in the middle. It is darker where it crosses itself, and darker again where you moved slowly.

That result is correct for flow. An airbrush adds paint in the same way. The result is incorrect for opacity. Opacity must be a limit, and the full stroke must never go past that limit.

## The stroke buffer

The solution is to keep the stroke off the layer until the stroke is complete.

While you draw, the dabs go into a separate buffer. The buffer holds one number for each pixel: how much of that pixel the stroke covers.

```zig
pub const Mask = struct {
    width: u32,
    height: u32,
    coverage: []u16,
    /// The colour that the stroke puts at each pixel. For most brushes, it is
    /// the brush colour at all pixels. A brush with pickup changes colour
    /// along the stroke. Thus the buffer must keep the colour for each pixel.
    /// The value has a meaning only where `coverage` is above 0. Thus the
    /// code never clears it.
    color: [][3]u8,
    /// Each pixel outside this rectangle is 0. With this rectangle, the
    /// commit, the clear and the redraw touch only the part of the image that
    /// the stroke touched.
    dirty: Rect = .empty,

    // ...
};
```

*Quoted from the source: `Mask` (fields only) from `examples/paint/src/engine/mask.zig`.*

When you release the pointer, the stroke goes onto the layer one time. The code multiplies its coverage by the opacity.

Dabs that overlap only increase the coverage towards 1. The opacity applies one time after that. Thus, where the coverage is 1, the stroke covers exactly 50%, and no more.

## Add coverage

Each dab adds `flow` multiplied by the part that has no coverage. In the stamp loop:

```zig
const new = old + ((full - old) * add + full - 1) / full;
m.coverage[i] = @intCast(new);
```

`full - old` is the part that has no coverage. `add` is the coverage of the dab at this pixel, multiplied by the flow.

After `n` dabs of flow `f`, the coverage is 1 − (1 − f)ⁿ. For example, two dabs at 20% flow give 1 − 0.8² = 0.36, not 0.40.

With each dab, the coverage moves nearer to 1. The coverage never goes past 1, for any number of dabs.

## Why 16 bits

The coverage is a `u16`: 0 is no coverage, and 65535 is full coverage.

Eight bits are not sufficient. The Airbrush in the studio has a flow of 4%. In 8 bits, 4% of 255 is 10.2, and the rounding makes it 10.

There is a worse problem. The soft edge of a tip contains small fractions of that 10. The rounding makes them 0, 1, 2 and 3, and the edge has visible steps.

In 16 bits, 4% is 2621, and the steps are too small to see.

## The rounding bug that a test found

The line above rounds the step **up**: it adds `full - 1` before the division.

The first version rounded to the nearest value, and a test found the problem. The test stamps 200 dabs at 30% flow and expects full coverage. With the rounding to the nearest value, the coverage stopped at 65534.

At 65534, the part without coverage is 1. One dab adds 30% of 1, which is 0.3, and the rounding makes 0.3 into 0. Thus each subsequent dab added nothing, and the stroke never gave a pixel full coverage.

When the code rounds up, the step is at least 1 while some part has no coverage. The step still never goes past full, because the step after rounding up is never larger than the gap that it fills.

## Put the stroke on the layer

`endStroke` does three things:

1. It keeps the old pixels for undo.
2. It applies the stroke to each pixel that the buffer touched.
3. It clears the buffer.

```zig
    /// Put the stroke onto its layer, once, and keep the old pixels for undo.
    pub fn endStroke(d: *Document) void {
        const active = d.stroke orelse return;
        const r = d.mask.dirty;
        const layer = d.layers[active.layer];

        d.history_ok = d.history.record(d.gpa, active.layer, layer, d.width, r);

        var y = r.y0;
        while (y < r.y1) : (y += 1) {
            var x = r.x0;
            while (x < r.x1) : (x += 1) {
                const i = @as(usize, y) * d.width + x;
                layer[i] = applyStroke(active, layer[i], d.mask.coverage[i], d.mask.color[i]);
            }
        }
        d.mask.clear();
        d.stroke = null;
        d.stale = d.stale.join(r);
    }
```

*Quoted from the source: `endStroke` from `examples/paint/src/engine/document.zig`.*

`endStroke` examines only `mask.dirty`, the rectangle that the dabs of the stroke touched. A short stroke in a corner touches only that corner, not the full layer.

`applyStroke` does the work for each pixel:

```zig
    /// One pixel of a layer with the stroke applied. The preview on the screen
    /// and the commit both call this function. Thus the stroke that you see
    /// while you draw is exactly the stroke that you get when you release it.
    fn applyStroke(active: Active, below: Rgba, coverage: u16, color: [3]u8) Rgba {
        const amount = (@as(u32, coverage) * active.opacity + 32767) / 65535;
        return switch (active.tool) {
            .brush => pixel.paint(below, color, amount),
            .eraser => pixel.erase(below, amount),
        };
    }
```

*Quoted from the source: `applyStroke` from `examples/paint/src/engine/document.zig`.*

## What you see while you draw

The stroke is not on the layer until you release the pointer. But you must see the stroke while you draw.

Thus the code applies the stroke while it builds the screen. When it builds a pixel of the active layer, it runs the same `applyStroke` first:

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

The preview and the commit call the same function with the same numbers. Thus the stroke cannot change when you release the pointer. A test makes sure of this. It calculates the hash of the screen immediately before `endStroke` and immediately after it, and the two hashes must be the same.

## Cancel a stroke

Something can interrupt a stroke. The browser can take the pointer away when a dialog opens, or the window can lose focus in the middle of a stroke.

If the code commits half of a stroke, the result is a mark that the person did not complete. If the code does not change the buffer, an unwanted image of the stroke stays on the screen.

The stroke is still only in the buffer. Thus it is easy to cancel the stroke: clear the buffer and draw that rectangle again.

```zig
    /// Drop the current stroke, and change no layer. A front end calls this
    /// function when it loses the pointer during a stroke.
    pub fn cancelStroke(d: *Document) void {
        if (d.stroke == null) return;
        d.stale = d.stale.join(d.mask.dirty);
        d.mask.clear();
        d.stroke = null;
    }
```

*Quoted from the source: `cancelStroke` from `examples/paint/src/engine/document.zig`.*

## Checks

This test is the example from above:

```zig
test "two dabs at 20% flow give 36%, not 40%" {
    var m = try Mask.init(std.testing.allocator, 32, 32);
    defer m.deinit(std.testing.allocator);
    const dab: Dab = .{ .x = 16, .y = 16, .radius = 10, .angle = 0, .direction = 0, .color = .{ 0, 0, 0 }, .load = 1 };
    m.stamp(dab, 1, 1, 0.2);
    m.stamp(dab, 1, 1, 0.2);
    const centre = @as(f32, @floatFromInt(m.at(16, 16))) / full;
    try std.testing.expectApproxEqAbs(@as(f32, 0.36), centre, 0.0001);
}
```

*Quoted from the source: `two dabs at 20% flow give 36%, not 40%` from `examples/paint/src/engine/mask.zig`.*

This test found the rounding bug:

```zig
test "many dabs approach full coverage and never pass it" {
    var m = try Mask.init(std.testing.allocator, 16, 16);
    defer m.deinit(std.testing.allocator);
    for (0..200) |_| m.stamp(.{ .x = 8, .y = 8, .radius = 6, .angle = 0, .direction = 0, .color = .{ 0, 0, 0 }, .load = 1 }, 1, 1, 0.3);
    try std.testing.expectEqual(@as(u16, 65535), m.at(8, 8));
}
```

*Quoted from the source: `many dabs approach full coverage and never pass it` from `examples/paint/src/engine/mask.zig`.*

In this test, a stroke at 50% opacity goes over itself again and stays at 50%:

```zig
test "a stroke crossing itself does not get darker" {
    var d = try newDoc();
    defer d.deinit();
    // Half opacity, full flow: the stroke gets full coverage, and then the
    // opacity applies one time.
    const brush: Brush = .{ .radius = 4, .flow = 1, .opacity = 0.5, .color = .{ 0, 0, 0 } };
    d.beginStroke(brush, .brush, .{ .x = 5, .y = 20 });
    d.moveStroke(.{ .x = 60, .y = 20 });
    d.moveStroke(.{ .x = 5, .y = 20 }); // back over the same line
    d.endStroke();
    try testing.expectEqual(@as(u8, 128), d.layers[0][20 * 64 + 30].a);
}
```

*Quoted from the source: `a stroke crossing itself does not get darker` from `examples/paint/src/engine/document.zig`.*

Opacity 0 must change nothing:

```zig
test "opacity 0 leaves the layer unchanged" {
    var d = try newDoc();
    defer d.deinit();
    d.beginStroke(.{ .opacity = 0 }, .brush, .{ .x = 10, .y = 10 });
    d.moveStroke(.{ .x = 50, .y = 30 });
    d.endStroke();
    for (d.layers[0]) |p| try testing.expectEqual(Rgba.transparent, p);
}
```

*Quoted from the source: `opacity 0 leaves the layer unchanged` from `examples/paint/src/engine/document.zig`.*

A cancelled stroke must leave nothing, on the screen or in the history:

```zig
test "cancelling a stroke leaves no ghost" {
    var d = try newDoc();
    defer d.deinit();
    _ = d.render();
    const blank = d.displayHash();
    d.beginStroke(.{}, .brush, .{ .x = 10, .y = 10 });
    d.moveStroke(.{ .x = 40, .y = 40 });
    d.cancelStroke();
    _ = d.render();
    try testing.expectEqual(blank, d.displayHash());
    try testing.expect(!d.history.canUndo());
}
```

*Quoted from the source: `cancelling a stroke leaves no ghost` from `examples/paint/src/engine/document.zig`.*

## Explain before you read the answer

You draw one stroke at 50% opacity. Then you draw a second stroke at 50% across the first stroke.

Where the strokes cross, is the colour 50% or 75%?

The colour is 75%. Each stroke has its own buffer, thus each stroke has a limit of 50%. But the second stroke goes over the result of the first stroke, as a second layer of paint does. The result is the first 50%, plus 50% of the 50% that had no coverage.
