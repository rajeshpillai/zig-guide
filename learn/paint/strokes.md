# Strokes

> Pointer samples come at irregular distances. Move along the path, put a dab at a fixed distance, and keep the distance that remains for the next segment.

A brush stroke is a row of marks. Each mark is a **dab**, and a dab is one stamp of the brush tip.

If many dabs are near each other at equal distances, they look like one continuous line.

## The obvious answer is wrong

While you hold the button, the pointer sends its position again and again. Each position report is a **sample**.

The obvious answer is one dab for each sample. That answer fails, because the samples do not come at equal distances.

The browser sends a sample when it can, about one time for each screen frame:

- A slow movement gives samples that are one or two pixels apart.
- A fast movement gives samples that are 40 pixels apart, with nothing between them.

Thus one dab for each sample draws a solid line when you move slowly. When you move fast, it draws a row of separate dots.

## Distance and lerp

The stroke code needs two small tools first.

The distance between two points is the length of the straight line between them:

```zig
/// Straight-line distance, in pixels. A movement backwards gives the same distance.
pub fn distance(a: Point, b: Point) f32 {
    return std.math.hypot(b.x - a.x, b.y - a.y);
}
```

*Quoted from the source: `distance` from `examples/paint/src/engine/geometry.zig`.*

From (10, 20) to (40, 60), the change in x is 30, and the change in y is 40. The distance is √(900 + 1600) = 50 pixels. A movement in the opposite direction gives negative changes, but the distance is the same.

`lerp` gives the value at a fraction `t` of the distance from `a` to `b`:

```zig
/// The value a fraction `t` of the way from `a` to `b`. `t` is not clamped:
/// `t = 1.5` goes past `b`.
pub fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}
```

*Quoted from the source: `lerp` from `examples/paint/src/engine/geometry.zig`.*

From 20 to 100, `t = 0.25` gives 40. `t = 0` gives 20, and `t = 1` gives 100.

`t = 1.5` gives 140, which is after the end. `lerp` does not clamp, and the stroke code never needs a clamp.

## Move along the path

The solution is to ignore the positions of the samples.

Between two samples, the pointer moved along a line. The stroke code moves along that line and puts a dab after each `gap` pixels.

The gap comes from the brush. The gap is a fraction of the radius. Thus a large brush puts its dabs farther apart than a small brush:

```zig
    /// The gap between dabs, in pixels. Never below half a pixel, or a tiny
    /// brush would put thousands of dabs on one short segment.
    fn gap(s: Stroke) f32 {
        return @max(s.brush.spacing * s.brush.radius, 0.5);
    }
```

*Quoted from the source: `gap` from `examples/paint/src/engine/stroke.zig`.*

A spacing of 0.25 on a brush of radius 40 gives a gap of 10 pixels.

## The distance that remains

If the code examines each segment separately, there is still a problem.

For example, the gap is 10, and the pointer moves 6 pixels. A dab does not fit in 6 pixels. Then the pointer moves 6 more pixels. If each segment starts its count at zero, a dab does not fit in the second segment either. The pointer moved 12 pixels, and the stroke has no dab after the first dab.

Thus the code keeps the distance from the last dab. This distance is the **carry**. After the first 6-pixel movement, the carry is 6.

The next segment does not need a full gap before its first dab. It needs only the 4 pixels that complete the interval: 10 − 6 = 4.

Each new sample goes through the function `move`:

```zig
    /// The pointer moved to `p`. Put each dab that is on the path.
    pub fn move(s: *Stroke, p: Point, sink: anytype) void {
        // Smoothing: move part of the distance to the real point.
        s.filtered = geometry.lerpPoint(s.filtered, p, s.brush.follow);

        const a = s.last;
        const b = s.filtered;
        const d = geometry.distance(a, b);
        // Two samples at the same position: there is no distance to move. A
        // division by `d` below would give NaN.
        if (d == 0) return;
        s.direction = std.math.atan2(b.y - a.y, b.x - a.x);

        const step = s.gap();
        // The first dab on this segment completes the interval that remains
        // from the last segment.
        var at = step - s.carry;
        while (at <= d) : (at += step) {
            // The load decreases with distance, not with each dab or sample. One
            // gap farther along the path uses `drain * step / 100` of a load.
            s.load = @max(s.load - s.brush.drain * step / 100.0, 0);
            s.emit(geometry.lerpPoint(a, b, at / d), sink);
        }
        s.carry = d - (at - step);
        s.last = b;
    }
```

*Quoted from the source: `move` from `examples/paint/src/engine/stroke.zig`.*

`at` is the distance along this segment to the position of the next dab. Its first value is `step - s.carry`, which is 4 pixels in the example.

The loop puts a dab and adds a gap. The loop continues while `at` is inside the segment.

When the loop ends, `at` is one gap after the last dab. Thus `at - step` is the position of the last dab. `d - (at - step)` is the length of the segment after the last dab, and that length is the new carry.

After the loop, the carry is always less than one gap.

## Two small details

Two samples can have exactly the same position. Then the distance is 0, and `at / d` is a division by zero, which gives NaN. A NaN position puts a dab nowhere, and it makes all of the calculations after it incorrect. Thus `move` returns immediately when `d == 0`.

A stroke must also make a mark when you click without a movement. Thus `begin` puts the first dab at the start point, and sets the carry to 0:

```zig
    /// Start a stroke at `p` and put the first dab there, so a click with no
    /// movement still leaves a mark.
    pub fn begin(brush: Brush, p: Point, sink: anytype) Stroke {
        const b = brush.sanitized();
        var s: Stroke = .{
            .brush = b,
            .random = .init(b.seed),
            .filtered = p,
            .last = p,
            .carry = 0,
            .direction = 0,
            .loaded = .{ @floatFromInt(b.color[0]), @floatFromInt(b.color[1]), @floatFromInt(b.color[2]) },
            .load = 1,
        };
        s.emit(p, sink);
        return s;
    }
```

*Quoted from the source: `begin` from `examples/paint/src/engine/stroke.zig`.*

## The destination of the dabs

`move` does not draw. It calls `sink.dab(...)`, and the caller decides what to do.

`sink` is `anytype`, thus any value with a `dab` method is correct. Zig examines this at compile time, separately for each type that a caller gives.

The document gives a painter that stamps each dab into the stroke buffer. A test gives a recorder that only keeps a list:

```zig
/// A sink for tests. It keeps the dabs that it receives.
const Recorder = struct {
    dabs: [256]Dab = undefined,
    len: usize = 0,
    /// The paint that `sample` returns for each dab.
    under: ?Sample = null,

    fn dab(r: *Recorder, d: Dab) void {
        r.dabs[r.len] = d;
        r.len += 1;
    }

    fn sample(r: *Recorder, x: f32, y: f32) ?Sample {
        _ = x;
        _ = y;
        return r.under;
    }
};
```

*Quoted from the source: `Recorder` from `examples/paint/src/engine/stroke.zig`.*

The stroke code is the same in the two cases. Only the action on the dabs changes.

## Checks

This test is the example from above: three movements of 6 pixels with a gap of 10.

```zig
test "carry after three moves of 6 pixels with a gap of 10 is 8" {
    // Radius 40 at spacing 0.25 is a gap of 10 pixels.
    const brush: Brush = .{ .radius = 40, .spacing = 0.25 };
    var rec: Recorder = .{};
    var s = Stroke.begin(brush, .{ .x = 0, .y = 0 }, &rec);
    s.move(.{ .x = 6, .y = 0 }, &rec);
    try std.testing.expectEqual(@as(f32, 6), s.carry);
    s.move(.{ .x = 12, .y = 0 }, &rec);
    s.move(.{ .x = 18, .y = 0 }, &rec);
    try std.testing.expectEqual(@as(f32, 8), s.carry);

    // A dab at the start, and one at x = 10. Not one per sample.
    try std.testing.expectEqual(@as(usize, 2), rec.len);
    try std.testing.expectEqual(@as(f32, 0), rec.dabs[0].x);
    try std.testing.expectApproxEqAbs(@as(f32, 10), rec.dabs[1].x, 1e-4);
}
```

*Quoted from the source: `carry after three moves of 6 pixels with a gap of 10 is 8` from `examples/paint/src/engine/stroke.zig`.*

The first dab is at 0, and the second dab is at 10, one gap after the first. The second movement, from 6 to 12, puts the second dab 4 pixels into that movement.

The next test shows why the carry is necessary. The test draws one movement of 100 pixels. Then it draws the same 100 pixels as movements of 3 pixels. The two strokes must give the same dabs:

```zig
test "the spacing does not depend on how the movement was cut up" {
    const brush: Brush = .{ .radius = 20, .spacing = 0.25 };
    var one: Recorder = .{};
    var s1 = Stroke.begin(brush, .{ .x = 0, .y = 0 }, &one);
    s1.move(.{ .x = 100, .y = 0 }, &one);

    var many: Recorder = .{};
    var s2 = Stroke.begin(brush, .{ .x = 0, .y = 0 }, &many);
    var x: f32 = 0;
    while (x < 100) {
        x = @min(x + 3, 100);
        s2.move(.{ .x = x, .y = 0 }, &many);
    }

    try std.testing.expectEqual(one.len, many.len);
    for (one.dabs[0..one.len], many.dabs[0..many.len]) |a, b| {
        try std.testing.expectApproxEqAbs(a.x, b.x, 1e-3);
    }
}
```

*Quoted from the source: `the spacing does not depend on how the movement was cut up` from `examples/paint/src/engine/stroke.zig`.*

Without the carry, the second stroke puts a dab at the end of each 3-pixel movement, or at none of them.

This test examines the repeated sample:

```zig
test "a repeated sample adds no dab and does not divide by zero" {
    var rec: Recorder = .{};
    var s = Stroke.begin(.{}, .{ .x = 5, .y = 5 }, &rec);
    s.move(.{ .x = 5, .y = 5 }, &rec);
    try std.testing.expectEqual(@as(usize, 1), rec.len);
    try std.testing.expect(!std.math.isNan(s.carry));
}
```

*Quoted from the source: `a repeated sample adds no dab and does not divide by zero` from `examples/paint/src/engine/stroke.zig`.*

## Record and replay a stroke

A stroke is only its list of samples.

If you keep the list, you can draw the stroke again. With the same brush, the list draws the same dabs. With a different brush, it draws the same path in a different style.

The demo picture from the [first chapter](https://www.ziglang.in/learn/paint/a-paint-program/) is a replay of this type. Its samples are in the code. Thus a test can draw the picture and compare the pixels.

## Explain before you read the answer

You complete a stroke with a carry of 7 and lift the pen. Then you start a new stroke in a different position.

Must the new stroke start with a carry of 7?

No, it must not. The carry is the distance from the last dab of this stroke. A new stroke has no last dab. It starts its own spacing, with a dab at the point where the pen touches the surface. That is why `begin` sets `carry = 0`.
