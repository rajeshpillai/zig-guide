# Smoothing, Pressure and Scatter

> Make a shaky hand steady with a moving average. Get the size of each dab from pen pressure. Scatter dabs with a random generator that repeats.

The last chapter changed samples into dabs at equal distances. This chapter changes the dabs. There are three changes, and each change is a small number of lines:

- **Smoothing** moves the path, to make a shaky hand steady.
- **Pressure** changes the size of each dab.
- **Jitter and scatter** change the size and position of each dab at random. A brush such as a spray can uses them.

The third change has a condition. The random values must repeat exactly. If they do not repeat, no test can compare two pictures.

## Smoothing

A hand is not steady, and a mouse is less steady than a hand.

Smoothing keeps a second position, the **filtered** position. For each new sample, smoothing moves the filtered position only part of the distance to the sample:

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

The first line of `move` does all of the smoothing. `follow` is the fraction of the distance to move.

## An example

The filtered x is 100. A sample comes at x = 120. `follow` is 0.25.

The filtered x moves a quarter of the distance: 100 + (120 − 100) × 0.25 = 105.

The next sample is at 120 again. The filtered x moves a quarter of the distance that remains: 105 + 15 × 0.25 = 108.75.

A small movement of a few pixels gets the same calculation. Thus the movement becomes a quarter of its size. At `follow = 1`, the filtered point moves directly to the sample, and there is no smoothing.

The cost is a delay. The stroke is behind the pointer. When you release the pointer, the stroke ends before the last position of the pointer. A lower `follow` gives a steadier line and a longer delay. That is why the Ink brush in the studio uses 0.35, and the Spray brush uses 1.

## Pressure

A pen sends its pressure as a value from 0 to 1. A mouse has no pressure, and browsers send 0.5 while the button is down.

The `pressure` setting of the brush tells how much effect the pen has, from 0 (no effect) to 1 (full effect). This function calculates the size of each dab:

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

The size at full effect is `0.25 + 0.75 × p²`, where `p` is the pressure of the pen.

At full pressure, the size is 1, which is the full radius. At no pressure, the size is 0.25, which is a quarter of the radius. Because of the square, light pressure has less effect. This feels more like a real pen than a straight line does.

Then the brush setting selects a value between that size and the full size with a `lerp`. At setting 0, the dab always has the full size, and the engine ignores the pen.

For a radius of 20, at setting 1:

- Pressure 1 gives 20 × (0.25 + 0.75) = 20 pixels.
- Pressure 0.5 gives 20 × (0.25 + 0.1875) = 8.75 pixels.
- Pressure 0 gives 20 × 0.25 = 5 pixels.

## Random numbers that repeat

The Spray brush changes the size and position of each dab at random.

Usually, a program gets random numbers from the operating system, and the numbers are different each time the program runs. That causes two problems:

- A test cannot draw with the spray brush and compare the result with a number.
- A recorded stroke draws differently each time that you replay it.

Thus the engine makes its own random numbers from a **seed**. The same seed gives the same numbers in the same order, on all computers:

```zig
pub const Random = struct {
    /// Always between 1 and 2^31 - 2. A zero state always stays zero.
    state: u32,

    const modulus: u64 = 2147483647; // 2^31 - 1, a prime
    const multiplier: u64 = 16807; // 7^5

    pub fn init(seed: u32) Random {
        const s: u32 = @intCast(seed % modulus);
        return .{ .state = if (s == 0) 1 else s };
    }

    /// The next value, from 0.0 to 1.0.
    pub fn next(r: *Random) f32 {
        // The product needs 46 bits, thus the code calculates it in u64. In u32
        // it would overflow, and Zig would stop the program in a safe build.
        r.state = @intCast((@as(u64, r.state) * multiplier) % modulus);
        return @as(f32, @floatFromInt(r.state - 1)) / 2147483646.0;
    }
};
```

*Quoted from the source: `Random` from `examples/paint/src/engine/random.zig`.*

This is the "minimal standard" generator of Park and Miller, from 1988. Each step multiplies the state by 16807. Then it keeps the remainder after a division by 2³¹ − 1.

The product can need 46 bits. Thus the code calculates it in a `u64`, because a `u32` overflows. In safe builds, Zig examines integer overflow. Thus an overflow stops the program with a message, and it does not silently give incorrect numbers.

Each brush has a seed. After each stroke, the studio adds one to the seed. Thus two spray strokes look different, but a replayed stroke looks the same.

## Jitter and scatter

In `emit`, the code takes three random numbers for each dab.

**Jitter** makes the dab smaller by a random quantity. At jitter 0.6, a dab is between 40% and 100% of its size.

**Scatter** moves the dab to a random point in a disc around its position on the path. The radius of the disc is `scatter` multiplied by the brush radius.

The random point is an angle and a distance. The angle is `2π × u`. The distance is `R × √v`.

The square root is necessary. Without the square root, half of the dabs are within half of the radius. But that inner circle is only a quarter of the area of the disc. The dabs collect at the centre.

With the square root, half of the dabs are within `R × √0.5`, about 71% of the radius. That circle is exactly half of the area, and the dabs spread equally.

The code takes the three numbers even when jitter and scatter are off. If the code takes them only when it uses them, the sequence moves when you turn scatter on. Then the jitter of each subsequent dab also changes.

## Checks

This test is the smoothing example from above:

```zig
test "smoothing moves a quarter of the way" {
    var rec: Recorder = .{};
    var s = Stroke.begin(.{ .follow = 0.25 }, .{ .x = 100, .y = 0 }, &rec);
    s.move(.{ .x = 120, .y = 0 }, &rec);
    try std.testing.expectEqual(@as(f32, 105), s.filtered.x);
    s.move(.{ .x = 120, .y = 0 }, &rec);
    try std.testing.expectEqual(@as(f32, 108.75), s.filtered.x);
}
```

*Quoted from the source: `smoothing moves a quarter of the way` from `examples/paint/src/engine/stroke.zig`.*

This test examines pressure at its two settings:

```zig
test "pressure: ignored at 0, a quarter size at full effect and no pressure" {
    var rec: Recorder = .{};
    _ = Stroke.begin(.{ .radius = 20, .pressure = 0 }, .{ .x = 0, .y = 0, .pressure = 0 }, &rec);
    _ = Stroke.begin(.{ .radius = 20, .pressure = 1 }, .{ .x = 0, .y = 0, .pressure = 0 }, &rec);
    _ = Stroke.begin(.{ .radius = 20, .pressure = 1 }, .{ .x = 0, .y = 0, .pressure = 1 }, &rec);
    try std.testing.expectEqual(@as(f32, 20), rec.dabs[0].radius);
    try std.testing.expectEqual(@as(f32, 5), rec.dabs[1].radius);
    try std.testing.expectEqual(@as(f32, 20), rec.dabs[2].radius);
}
```

*Quoted from the source: `pressure: ignored at 0, a quarter size at full effect and no pressure` from `examples/paint/src/engine/stroke.zig`.*

This test uses the published values of the generator. Park and Miller give the states after seed 1. Thus an incorrect multiplier or an incorrect modulus causes this test to fail:

```zig
test "the first values from seed 1 are the published ones" {
    // Park and Miller give 16807, 282475249 and 1622650073 as the first three
    // states from seed 1. Thus this test finds an incorrect multiplication.
    var r = Random.init(1);
    _ = r.next();
    try std.testing.expectEqual(@as(u32, 16807), r.state);
    _ = r.next();
    try std.testing.expectEqual(@as(u32, 282475249), r.state);
    _ = r.next();
    try std.testing.expectEqual(@as(u32, 1622650073), r.state);
}
```

*Quoted from the source: `the first values from seed 1 are the published ones` from `examples/paint/src/engine/random.zig`.*

This test examines scatter. Each dab must be in the disc, and the same seed must give the same dabs:

```zig
test "scatter stays inside the disc, and the same seed repeats it" {
    const brush: Brush = .{ .radius = 10, .scatter = 2, .seed = 7 };
    var a: Recorder = .{};
    var b: Recorder = .{};
    var sa = Stroke.begin(brush, .{ .x = 0, .y = 0 }, &a);
    var sb = Stroke.begin(brush, .{ .x = 0, .y = 0 }, &b);
    sa.move(.{ .x = 200, .y = 0 }, &a);
    sb.move(.{ .x = 200, .y = 0 }, &b);
    try std.testing.expectEqual(a.len, b.len);
    for (a.dabs[0..a.len], b.dabs[0..b.len], 0..) |da, db, i| {
        try std.testing.expectEqual(da, db);
        // The position of the dab on the path, before scatter, is i * gap.
        const along: f32 = @as(f32, @floatFromInt(i)) * 2.5;
        const off = std.math.hypot(da.x - along, da.y);
        try std.testing.expect(off <= 20.001);
    }
}
```

*Quoted from the source: `scatter stays inside the disc, and the same seed repeats it` from `examples/paint/src/engine/stroke.zig`.*

## Explain before you read the answer

A random number `u` is 0.25, and a second random number `v` is 0.25. The scatter radius `R` is 20 pixels.

Where does the dab move?

The angle is 2π × 0.25 = π/2, which is a quarter turn. The distance is 20 × √0.25 = 10 pixels.

A quarter turn from the x axis points along the y axis. On a screen, y increases downwards. Thus the dab moves 10 pixels straight down.
