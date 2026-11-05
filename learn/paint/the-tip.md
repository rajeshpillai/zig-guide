# The Tip

> A dab is a disc with a soft edge. Make it an ellipse, turn it, and the same twenty lines draw a soft brush, a calligraphy nib and a ribbon.

A dab tells where the brush touched and how large the dab was. The **tip** decides which pixels the dab covers, and how much it covers them.

For each pixel, the answer is a number from 0 to 1, the **coverage**. 1 is full coverage, 0 is no coverage, and 0.5 is half coverage.

The engine calculates the coverage for three types of tip:

- A round tip with a soft edge.
- A flat tip, which is an ellipse.
- A flat tip at an angle. The angle is fixed, or it follows the stroke.

## Which pixels to examine

A dab can touch only the pixels within its radius from its centre. Thus the code examines the square around the dab, cut at the edges of the image, and no other pixels:

```zig
    /// The pixels that a circle of `radius` around (`x`, `y`) can touch, cut
    /// to a `w` by `h` image. The function calculates in `f32` and clamps
    /// before the conversion, because a dab can start far outside the image.
    pub fn around(x: f32, y: f32, radius: f32, w: u32, h: u32) Rect {
        const fw: f32 = @floatFromInt(w);
        const fh: f32 = @floatFromInt(h);
        return .{
            .x0 = @intFromFloat(std.math.clamp(@floor(x - radius), 0, fw)),
            .y0 = @intFromFloat(std.math.clamp(@floor(y - radius), 0, fh)),
            .x1 = @intFromFloat(std.math.clamp(@ceil(x + radius), 0, fw)),
            .y1 = @intFromFloat(std.math.clamp(@ceil(y + radius), 0, fh)),
        };
    }
```

*Quoted from the source: `around` from `examples/paint/src/engine/geometry.zig`.*

A 20-pixel dab examines a 40 by 40 square, which is 1,600 pixels. The full 640 by 400 image is 256,000 pixels. Thus, for each dab, the square is 160 times less work.

The code calculates the square in `f32` and clamps it before it changes it to an integer. A dab can start far outside the image. A direct conversion from a negative `f32` to a `u32` is illegal behaviour, and Zig examines it in safe builds.

## A soft round tip

For a round tip, the coverage depends only on the distance `d` from the centre of the dab to the centre of the pixel.

The **hardness** of the brush is the solid part of the radius. With radius 20 and hardness 0.6:

- Inside 12 pixels (0.6 × 20), the coverage is 1.
- From 12 to 20 pixels, the coverage decreases in a straight line from 1 to 0.
- After 20 pixels, the coverage is 0.

At 16 pixels, which is the middle of the soft band, the coverage is 0.5.

At hardness 1, the band has no width. Then the edge of each dab is a staircase of full pixels. Thus the band is never narrower than one pixel. One pixel is sufficient to make the edge smooth.

## Pixel centres

A pixel is a small square, not a point. Pixel (5, 3) covers x from 5 to 6 and y from 3 to 4. Its centre is (5.5, 3.5).

The tip measures the distance to the centre. If the tip used the corner, each dab would be half a pixel up and to the left of its correct position. The [Scale and Resample](https://www.ziglang.in/learn/graphics/resample/) chapter shows how the same half-pixel mistake moves a full image.

## Make the tip flat and turn it

A calligraphy nib is not round. It is flat.

A flat tip is an ellipse. It has the full width along one axis, and `aspect` multiplied by that width along the other axis. With radius 20 and aspect 0.25, the tip is 40 pixels wide and 10 pixels high.

To draw an ellipse, the code changes the problem back into a circle:

1. Take the offset of the pixel from the centre, `dx` and `dy`.
2. Turn the offset by the angle of the tip. Then `u` is along the tip, and `v` is across it.
3. Divide `v` by the aspect.

Now a point on the edge of the ellipse is exactly on the circle with the original radius. Thus the coverage rule of the round tip works without a change.

This function is the full tip, with all three types:

```zig
    /// Add one dab of the tip.
    ///
    /// `hardness` is the solid fraction of the radius, `aspect` makes the tip
    /// an ellipse, and `flow` is how much one dab adds.
    pub fn stamp(m: *Mask, dab: Dab, hardness: f32, aspect: f32, flow: f32) void {
        m.stampOn(null, 1, dab, hardness, aspect, flow);
    }
```

*Quoted from the source: `stamp` from `examples/paint/src/engine/mask.zig`.*

The code calculates `@cos` and `@sin` one time for each dab, not one time for each pixel. A 20-pixel dab examines 1,600 pixels and uses the same two numbers for all of them.

## Follow the direction

A nib at a fixed angle gives calligraphy. Lines along the nib are thin, and lines across the nib are wide, with no change in pressure. The Calligraphy brush in the studio does this, at −45 degrees.

A tip can also turn with the stroke. The stroke knows its direction already. Each `move` calculates the direction from its segment:

```zig
s.direction = std.math.atan2(b.y - a.y, b.x - a.x);
```

`atan2` takes the change in y and the change in x, and returns the angle, from −π to π. A movement to the right gives 0. A movement down the page gives π/2, which is a quarter turn, because y increases downwards on a screen.

With `follow_direction`, the angle of the dab is that direction plus the angle of the brush:

- At 0, the flat tip is along the stroke, and it draws a thin line.
- At 90, the flat tip is across the stroke, and it draws a wide ribbon. The Ribbon brush does this.

## Checks

This test is the soft tip from the example. The tip is solid to 12 pixels, half at 16, and empty after 20.

```zig
test "radius 20, hardness 0.6 is solid to 12 and half at 16" {
    var m = try Mask.init(std.testing.allocator, 64, 64);
    defer m.deinit(std.testing.allocator);
    // Put the centre on a pixel corner. Then the centre of the pixel at
    // (32 + k, 32) is k + 0.5 pixels from the dab.
    m.stamp(.{ .x = 32, .y = 32, .radius = 20, .angle = 0, .direction = 0, .color = .{ 0, 0, 0 }, .load = 1 }, 0.6, 1, 1);
    const at = struct {
        fn f(mm: Mask, k: u32) f32 {
            return @as(f32, @floatFromInt(mm.at(32 + k, 32))) / full;
        }
    }.f;
    try std.testing.expectEqual(@as(f32, 1), at(m, 11)); // 11.5 from the centre
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), at(m, 15), 0.07); // 15.5
    try std.testing.expectEqual(@as(f32, 0), at(m, 20)); // 20.5, outside
}
```

*Quoted from the source: `radius 20, hardness 0.6 is solid to 12 and half at 16` from `examples/paint/src/engine/mask.zig`.*

The test puts the centre of the dab on a pixel corner. Thus the centre of the pixel at offset `k` is `k + 0.5` pixels away. That is why the checks use 11, 15 and 20.

This test examines the flat tip, and then the same tip after a quarter turn:

```zig
test "aspect 0.25 makes a tip 40 wide and 10 high" {
    var m = try Mask.init(std.testing.allocator, 64, 64);
    defer m.deinit(std.testing.allocator);
    m.stamp(.{ .x = 32, .y = 32, .radius = 20, .angle = 0, .direction = 0, .color = .{ 0, 0, 0 }, .load = 1 }, 1, 0.25, 1);
    try std.testing.expect(m.at(32 + 18, 32) > 0);
    try std.testing.expect(m.at(32, 32 + 6) == 0);
    try std.testing.expect(m.at(32, 32 + 3) > 0);
    // After a quarter turn, the same tip is tall, not wide.
    var t = try Mask.init(std.testing.allocator, 64, 64);
    defer t.deinit(std.testing.allocator);
    t.stamp(.{ .x = 32, .y = 32, .radius = 20, .angle = std.math.pi / 2.0, .direction = 0, .color = .{ 0, 0, 0 }, .load = 1 }, 1, 0.25, 1);
    try std.testing.expect(t.at(32, 32 + 18) > 0);
    try std.testing.expect(t.at(32 + 6, 32) == 0);
}
```

*Quoted from the source: `aspect 0.25 makes a tip 40 wide and 10 high` from `examples/paint/src/engine/mask.zig`.*

This test uses a dab that is mostly outside the image. The dab must touch only the pixels inside the image:

```zig
test "a dab past the edge touches nothing outside the image" {
    var m = try Mask.init(std.testing.allocator, 8, 8);
    defer m.deinit(std.testing.allocator);
    m.stamp(.{ .x = -3, .y = 4, .radius = 5, .angle = 0, .direction = 0, .color = .{ 0, 0, 0 }, .load = 1 }, 1, 1, 1);
    try std.testing.expectEqual(Rect{ .x0 = 0, .y0 = 0, .x1 = 2, .y1 = 8 }, m.dirty);
    m.clear();
    for (m.coverage) |c| try std.testing.expectEqual(@as(u16, 0), c);
}
```

*Quoted from the source: `a dab past the edge touches nothing outside the image` from `examples/paint/src/engine/mask.zig`.*

## Explain before you read the answer

The Calligraphy brush has an aspect of 0.2 and an angle of −45 degrees.

You draw a line from the bottom left to the top right of the page. Is the line thin or wide?

The line is thin. On the screen, y increases downwards, thus −45 degrees points up and to the right. That is the direction of your line. The long side of the nib is along the line, and the line is only as wide as the short side.
