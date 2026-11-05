# Oil: Pickup and Paint Load

> An oil brush carries paint. It collects some of the colour below it, and it becomes dry as it moves.

Each brush in the previous chapters puts down one colour. The colour is the same at the end of a stroke and at the start.

A brush with oil paint is different. Two things change while the brush moves:

- **Pickup.** The brush collects some of the paint below it. Thus its colour moves towards the colour below it.
- **Load.** The brush becomes dry. It has less paint after each centimetre, and the stroke becomes fainter.

Select the Oil brush in the studio. Paint some colours, and then pull the Oil brush across them.

## The brush carries paint

For these two effects, the stroke must keep two values from one dab to the next. The values are the colour on the brush and the quantity of paint that remains.

Thus the stroke has two new fields:

```zig
pub const Stroke = struct {
    brush: Brush,
    random: Random,
    /// The smoothed pointer position.
    filtered: Point,
    /// The end of the last segment. The next dabs start from here.
    last: Point,
    /// The distance since the last dab, in pixels. Always less than `gap`.
    carry: f32,
    /// The direction of movement, in radians. 0 (to the right) until the first move.
    direction: f32,
    /// The colour on the brush. It is in `f32`, thus small pickups accumulate,
    /// and the rounding does not remove them. Starts as the brush colour.
    loaded: [3]f32,
    /// The paint left on the brush. Every stroke starts with a full brush.
    load: f32,

    /// Start a stroke at `p` and put the first dab there, so a click with no
    /// movement still leaves a mark.

    // ...
};
```

*Quoted from the source: `Stroke` (fields only) from `examples/paint/src/engine/stroke.zig`.*

The first value of `loaded` is the brush colour. The first value of `load` is 1, which is a full brush. Each stroke starts with a full brush.

## Pickup

Before each dab, the brush examines the paint below it. Then it moves its colour part of the distance to that paint:

```
loaded = loaded + (under − loaded) × pickup
```

This is `lerp` again, one time each for red, green and blue.

For example, the loaded red is 200, the paint below it has red 100, and `pickup` is 0.2. The new loaded red is 200 + (100 − 200) × 0.2 = 180. Over the same paint again, the result is 180 + (100 − 180) × 0.2 = 164.

The brush carries the colour to the next dab. Thus the paint from one area moves a short distance along the stroke, and that is the smear.

The pickup occurs in `emit`:

```zig
    fn emit(s: *Stroke, p: Point, sink: anytype) void {
        const b = s.brush;

        // Pressure: at `pressure = 0` the size ignores the pen.
        // At 1, a light touch draws at a quarter of the size.
        const p2 = p.pressure * p.pressure;
        var radius = b.radius * geometry.lerp(1.0, 0.25 + 0.75 * p2, b.pressure);

        // Three random numbers for each dab, also if the code does not use them.
        // Thus a change to scatter does not change the size of each later dab.
        const u_size = s.random.next();
        const u_angle = s.random.next();
        const u_reach = s.random.next();

        radius *= 1.0 - b.jitter * u_size;

        // Scatter across a disc. The square root spreads the offsets equally
        // over the area. Without it, the offsets collect at the centre.
        const theta = 2.0 * std.math.pi * u_angle;
        const reach = b.scatter * b.radius * @sqrt(u_reach);
        const x = p.x + @cos(theta) * reach;
        const y = p.y + @sin(theta) * reach;

        // Pickup: before the dab, the brush takes part of the paint that is
        // already below it. The brush carries the colour to the next dab. Thus
        // paint moves along the stroke. Thin paint gives less, and empty paper
        // gives nothing: a brush cannot collect the paper.
        if (b.pickup > 0) {
            if (sink.sample(x, y)) |under| {
                const t = b.pickup * under.cover;
                for (&s.loaded, under.color) |*c, u| c.* = geometry.lerp(c.*, @floatFromInt(u), t);
            }
        }

        sink.dab(.{
            .x = x,
            .y = y,
            .radius = radius,
            // When the tip follows the direction, the brush angle is an offset from
            // the direction. 0 puts the tip along the stroke, and 90 puts it across.
            .angle = (if (b.follow_direction) s.direction else 0) + b.angle * std.math.pi / 180.0,
            .direction = s.direction,
            .color = .{
                @intFromFloat(@round(s.loaded[0])),
                @intFromFloat(@round(s.loaded[1])),
                @intFromFloat(@round(s.loaded[2])),
            },
            .load = s.load,
        });
    }
```

*Quoted from the source: `emit` from `examples/paint/src/engine/stroke.zig`.*

The code keeps `loaded` in `f32`, not in bytes. A small pickup moves each channel by less than 1. In bytes, the rounding removes that change. Then a brush with a low pickup never changes colour.

## The brush cannot collect paper

The first version of the code took its sample from the picture on the screen: the layer over white paper.

The oil stroke in the demo is red, and it starts on empty paper. After a small number of dabs, the brush was white. Then it painted white over the dark stroke below it. The brush collected the paper.

Paper is not paint. Thus the code now takes the sample from the layer. The sample gives the quantity of paint and also its colour:

```zig
        /// The paint that is already on the active layer at (`x`, `y`): its
        /// colour, and how much of the pixel it covers. The function reads the
        /// layer, not the stroke buffer. Thus a brush collects the paint below it,
        /// and never collects the current stroke. Empty paper is not paint, thus
        /// it gives nothing.
        pub fn sample(p: Painter, x: f32, y: f32) ?Sample {
            const doc = p.doc;
            if (!(x >= 0 and y >= 0)) return null;
            const ux: u32 = @intFromFloat(@min(x, @as(f32, @floatFromInt(doc.width - 1))));
            const uy: u32 = @intFromFloat(@min(y, @as(f32, @floatFromInt(doc.height - 1))));
            const px = doc.layers[doc.active_layer][@as(usize, uy) * doc.width + ux];
            if (px.a == 0) return null;
            // Layers are premultiplied. Thus the colour of the paint is each
            // channel divided by the alpha.
            const a: u32 = px.a;
            return .{
                .color = .{
                    @intCast((@as(u32, px.r) * 255 + a / 2) / a),
                    @intCast((@as(u32, px.g) * 255 + a / 2) / a),
                    @intCast((@as(u32, px.b) * 255 + a / 2) / a),
                },
                .cover = @as(f32, @floatFromInt(a)) / 255.0,
            };
        }
```

*Quoted from the source: `sample` from `examples/paint/src/engine/document.zig`.*

Empty paper returns `null`, thus the brush collects nothing. If paint covers half of a pixel, the paint has half of the effect: the code multiplies the pickup by `cover`.

Layers are premultiplied, as the [Layers](https://www.ziglang.in/learn/paint/layers-and-the-eraser/) chapter explains. If red 200 covers half of a pixel, the layer stores red 100. To get the colour of the paint, `sample` divides by the alpha.

The sample also comes from the layer, and never from the stroke buffer. Thus the brush collects paint that was there before the stroke. It never collects the current stroke.

## A stroke of many colours

The stroke buffer in [Flow and Opacity](https://www.ziglang.in/learn/paint/flow-and-opacity/) held one number for each pixel, the coverage. The colour was the brush colour, the same at all pixels.

With pickup, two dabs of one stroke can have different colours. Thus the buffer now also keeps a colour for each pixel:

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

When a dab adds coverage to a pixel, the colour of the pixel changes. The new colour is the average of the old colour and the colour of the dab. The weight of each colour is the coverage that it added.

For example, a red dab at 50% flow covers half of a pixel. A blue dab at 50% covers half of the remainder, which is a quarter. Red added two times as much as blue. Thus the colour is two thirds red and one third blue.

That weighted average is the same result as blue paint on red paint. When the two colours are the same, the average is exactly that colour, with no rounding error. Thus each brush without pickup draws the same pixels as before this change.

A test proved this. Before the change, the demo picture had a fixed hash. After the change, all of the tests ran, and the hash did not change. Only after that did the demo get an oil stroke and a new fixed hash.

## The brush becomes dry

The load decreases with distance. It does not decrease with time or with pointer samples. The [Strokes](https://www.ziglang.in/learn/paint/strokes/) chapter shows why samples are a bad measurement.

The stroke already moves along the path one gap at a time. Thus each gap uses a fixed part of the load:

```zig
s.load = @max(s.load - s.brush.drain * step / 100.0, 0);
```

`drain` is the part of a full load that the brush uses in each 100 pixels. With `drain` 0.2, 150 pixels of stroke use 0.3. Then 0.7 of a full load remains.

The load never goes below 0. The code multiplies the flow of each dab by the load. Thus a stroke becomes fainter smoothly while the brush becomes empty.

## Checks

This test is the pickup example, with 200, then 180, then 164:

```zig
test "pickup: the loaded red goes 200, 180, 164 over a red of 100 at 0.2" {
    var rec: Recorder = .{ .under = .{ .color = .{ 100, 0, 0 } } };
    var s = Stroke.begin(.{ .radius = 40, .spacing = 0.25, .pickup = 0.2, .color = .{ 200, 0, 0 } }, .{ .x = 0, .y = 0 }, &rec);
    try std.testing.expectEqual(@as(u8, 180), rec.dabs[0].color[0]);
    s.move(.{ .x = 10, .y = 0 }, &rec);
    try std.testing.expectEqual(@as(u8, 164), rec.dabs[1].color[0]);
}
```

*Quoted from the source: `pickup: the loaded red goes 200, 180, 164 over a red of 100 at 0.2` from `examples/paint/src/engine/stroke.zig`.*

This test makes sure that thin paint gives less pickup:

```zig
test "pickup from paint that half covers the paper is half as strong" {
    var rec: Recorder = .{ .under = .{ .color = .{ 100, 0, 0 }, .cover = 0.5 } };
    _ = Stroke.begin(.{ .pickup = 0.2, .color = .{ 200, 0, 0 } }, .{ .x = 0, .y = 0 }, &rec);
    try std.testing.expectEqual(@as(u8, 190), rec.dabs[0].color[0]);
}
```

*Quoted from the source: `pickup from paint that half covers the paper is half as strong` from `examples/paint/src/engine/stroke.zig`.*

This test is the drain example. It cuts the stroke into samples in two ways, and the two results must be the same:

```zig
test "drain 0.2 over 150 pixels uses 0.3 of a load, whatever the samples" {
    // A gap of 10 pixels. 150 pixels of stroke is 15 gaps.
    const brush: Brush = .{ .radius = 40, .spacing = 0.25, .drain = 0.2 };
    var one: Recorder = .{};
    var s1 = Stroke.begin(brush, .{ .x = 0, .y = 0 }, &one);
    s1.move(.{ .x = 150, .y = 0 }, &one);
    var many: Recorder = .{};
    var s2 = Stroke.begin(brush, .{ .x = 0, .y = 0 }, &many);
    var x: f32 = 0;
    while (x < 150) {
        x = @min(x + 7, 150);
        s2.move(.{ .x = x, .y = 0 }, &many);
    }
    try std.testing.expectApproxEqAbs(@as(f32, 0.7), s1.load, 1e-5);
    try std.testing.expectApproxEqAbs(s1.load, s2.load, 1e-5);
    // The load never goes below empty.
    s1.move(.{ .x = 2000, .y = 0 }, &one);
    try std.testing.expectEqual(@as(f32, 0), s1.load);
}
```

*Quoted from the source: `drain 0.2 over 150 pixels uses 0.3 of a load, whatever the samples` from `examples/paint/src/engine/stroke.zig`.*

This test examines how the stroke buffer mixes colours:

```zig
test "two colours mix by the coverage each one added" {
    var m = try Mask.init(std.testing.allocator, 16, 16);
    defer m.deinit(std.testing.allocator);
    const at: Dab = .{ .x = 8, .y = 8, .radius = 6, .angle = 0, .direction = 0, .color = .{ 200, 0, 0 }, .load = 1 };
    m.stamp(at, 1, 1, 0.5);
    var blue = at;
    blue.color = .{ 0, 0, 200 };
    m.stamp(blue, 1, 1, 0.5);
    // Red covered half, then blue covered half of the remainder. Red added
    // two times as much as blue.
    const c = m.color[8 * 16 + 8];
    try std.testing.expectEqual([3]u8{ 133, 0, 67 }, c);
}
```

*Quoted from the source: `two colours mix by the coverage each one added` from `examples/paint/src/engine/mask.zig`.*

## Explain before you read the answer

Set `pickup` to 1. Then pull the brush from a blue area onto empty paper.

What does the brush paint?

Over the blue, each dab takes all of the blue below it. Thus the brush paints blue on blue, and nothing seems to change. On the paper, there is nothing to collect. Thus the brush keeps the last blue that it took, and paints that blue on the paper. The stroke pulls the blue out of its area, as a finger does through wet paint.
