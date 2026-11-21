# Watercolour

> Water and pigment on a grid of paper. They spread, the paper dries, and pigment settles into it. Fixed steps make each run the same on all computers.

Wet paint on wet paper does not stay where the brush put it.

The water spreads into the paper around it, and the water carries the colour. Then the paper dries, and the colour stays where the water left it.

The brushes in the previous chapters cannot do this. A brush decides each pixel one time, when the dab occurs. Watercolour continues to change after the brush moves away.

Thus this is a separate experiment with its own state, and the experiment runs over time:

*Interactive: the watercolour simulation, compiled to WebAssembly. Click to drop water and pigment. Drag for a trail. Each step is 1/30 of a second. It runs on the web page of this chapter.*

## A grid of paper

The program divides the paper into cells, 80 across and 50 down. On the 640 by 400 page, each cell is 8 by 8 pixels.

Each cell keeps three numbers:

- **water**: how wet the paper is, from 0 (dry) to 1 (fully wet).
- **mobile**: pigment that is still in the water. This pigment can move.
- **deposited**: pigment that is now in the paper. This pigment cannot move.

```zig
pub const Watercolor = struct {
    width: u32,
    height: u32,
    water: []f32,
    mobile: []f32,
    deposited: []f32,
    /// How quickly pigment settles in each cell, from 0.6 to 1.4 times the
    /// base rate. The code makes it one time, thus the grain of the paper
    /// does not move.
    grain: []f32,
    /// The second buffer for the spread. A step reads one buffer and writes
    /// the other, then swaps them.
    next: []f32,

    /// How fast water and pigment spread. At most 0.25: see `spread`.
    spread_rate: f32 = 0.18,
    /// How much of its wetness the paper keeps after one second.
    retention: f32 = 0.8,
    /// How fast mobile pigment settles, per second.
    settle_rate: f32 = 0.8,
    /// The pigment's colour.
    color: [3]u8 = .{ 40, 90, 160 },

    // ...
};
```

*Quoted from the source: `Watercolor` (fields only) from `examples/paint/src/engine/watercolor.zig`.*

The program stores a grid as one long array, row by row. Cell (x, y) is at `y * width + x`. On a grid 80 wide, cell (3, 2) is number 2 × 80 + 3 = 163.

80 × 50 is 4,000 cells. One `f32` field is 16,000 bytes, and all five fields are 80,000 bytes. The grid is coarse on purpose. The full simulation fits in a small cache, and it runs 30 times each second on a slow laptop.

The picture on the page is these 4,000 cells, scaled up smoothly. The blur from the scaling gives the soft edge that watercolour must have.

## Neighbours

Water spreads to the cells next to it: left, right, above and below.

At the edge of the paper, some of those cells do not exist. The code examines the coordinates before it makes an index:

```zig
    /// Left, right, above and below, or null where that neighbour is
    /// outside the paper. The code examines the coordinate first. Thus a
    /// cell on the left edge cannot get to the right edge of the row above.
    pub fn neighbours(w: Watercolor, x: u32, y: u32) [4]?usize {
        return .{
            if (x > 0) w.index(x - 1, y) else null,
            if (x + 1 < w.width) w.index(x + 1, y) else null,
            if (y > 0) w.index(x, y - 1) else null,
            if (y + 1 < w.height) w.index(x, y + 1) else null,
        };
    }
```

*Quoted from the source: `neighbours` from `examples/paint/src/engine/watercolor.zig`.*

If the code examined the index instead, that would be a bug. The cell to the left of (0, 5) would be index 5 × 80 − 1 = 399. That index is the last cell of row 4, on the opposite side of the paper.

A middle cell has four neighbours, and a corner has two. Water at an edge can only move back in. Thus the paper keeps all of its water.

## Spread

In each step, each cell moves a small distance towards each of its neighbours:

```
next = current + rate × (sum of (neighbour − current))
```

With `rate` 0.18, a fully wet centre with four dry neighbours keeps 1 + 0.18 × (−4) = 0.28. Each neighbour gets 0.18. The total is still 1.

```zig
    /// Spread `field` between neighbour cells. Read the old values, and
    /// write the new values to a second buffer.
    ///
    /// Each cell moves towards its neighbours by `spread_rate` multiplied by
    /// each difference. A cell with four neighbours keeps `1 - 4 * rate` of
    /// its own value. Thus `rate` must be 0.25 or less. If not, that weight
    /// is negative, and values can go too far, change sign and grow without
    /// limit.
    ///
    /// `order` exists only to show that the order has no effect. No cell
    /// reads a value from the same step. Thus a backwards scan gives the
    /// same result.
    pub fn spread(w: *Watercolor, field: []f32, wet: ?[]const f32, order: Order) void {
        const n = field.len;
        for (0..n) |k| {
            const i = if (order == .forward) k else n - 1 - k;
            const x: u32 = @intCast(i % w.width);
            const y: u32 = @intCast(i / w.width);
            var change: f32 = 0;
            for (w.neighbours(x, y)) |maybe| {
                const j = maybe orelse continue;
                var amount = w.spread_rate;
                if (wet) |water| amount *= @min(@min(water[i], water[j]), 1);
                change += amount * (field[j] - field[i]);
            }
            w.next[i] = field[i] + change;
        }
        @memcpy(field, w.next);
    }
```

*Quoted from the source: `spread` from `examples/paint/src/engine/watercolor.zig`.*

## Read the old grid, write a new grid

`spread` reads from `field` and writes to `next`. Then it copies `next` back.

This is important. If `spread` wrote into `field` during the scan, the cell after a changed cell would read the new value, not the old value. Then the result would depend on the order of the scan, and water would move in the direction of the scan.

With two buffers, each cell reads the state from before the step. The `order` parameter exists only for a test. That test scans backwards and gets the same answer.

## A limit on the rate

A cell with four neighbours keeps `1 − 4 × rate` of its own value.

At 0.25, the cell keeps 0. Above 0.25, the value is negative. A cell gives away more water than it has, and its value goes below zero. Then the next step moves the value in the opposite direction, farther each time.

Thus, for this rule, the rate must be 0.25 or less. A test sets the rate to 0.4. In one step, the centre becomes negative.

If the code clamped the values to 0 after the step, it would hide the problem. It would also silently make or remove water. When the rate stays in its range, the model stays correct.

## Pigment moves with water

Pigment in the water spreads with the same rule, but only as fast as the wetness of the paper allows. Between two cells, the quantity that moves is in proportion to the wetness of the drier cell:

```zig
if (wet) |water| amount *= @min(@min(water[i], water[j]), 1);
```

Between two dry cells, nothing moves. That is why a dry stroke keeps its shape.

The quantity that moves from one cell to another is the same in the two directions. Thus the spread never makes or loses pigment.

## Dry the paper, with units

The paper must not dry two times as fast when the computer runs two times as many steps.

Thus the rate at which the paper dries is a rate for each second. `retention` is the part of its water that a cell keeps after one second. One step is `dt` seconds. Thus one step keeps `retention` to the power `dt`.

```zig
    /// One step of 1/30 of a second.
    pub fn step(w: *Watercolor) void {
        // Water spreads to drier neighbours. Pigment also spreads, but only
        // where the paper is wet. Between two cells, the pigment moves in
        // proportion to the wetness of the drier cell.
        w.spread(w.water, null, .forward);
        w.spread(w.mobile, w.water, .forward);

        // The paper dries. `retention` is what remains after one full second.
        // Thus one step of `dt` seconds keeps `retention` to the power `dt`.
        // Thirty steps then keep exactly `retention`, at any step size.
        const keep = std.math.pow(f32, w.retention, dt);
        for (w.water) |*v| v.* *= keep;

        // The pigment settles. A part of the mobile pigment moves into the
        // paper. The step moves it and does not remove it: the total pigment
        // does not change.
        for (w.mobile, w.deposited, w.grain) |*m, *d, g| {
            const share = 1.0 - @exp(-w.settle_rate * g * dt);
            const moved = m.* * share;
            m.* -= moved;
            d.* += moved;
        }
    }
```

*Quoted from the source: `step` from `examples/paint/src/engine/watercolor.zig`.*

With `retention` 0.8, thirty steps of 1/30 of a second keep 0.8, and sixty steps keep 0.64. Two half seconds give the same answer as one second, because powers multiply: 0.8^0.5 × 0.8^0.5 = 0.8.

## The pigment settles

If the picture showed only water, the picture would disappear when the paper dried. Thus pigment has its own state.

In each step, a part of the mobile pigment goes into the paper. That part comes from a rate for each second, in the same way as the rate for water. The part that stays mobile after `dt` seconds is `exp(−rate × dt)`. Thus the part that settles is one minus that value.

At rate 0.8, one step settles 1 − e^(−0.8/30), about 2.63%. From 0.6 of mobile pigment, about 0.0158 settles.

The step moves the pigment, but it does not remove it. `mobile` decreases by exactly the quantity that `deposited` increases. The total never changes.

Each cell multiplies the rate by its own **grain**, from 0.6 to 1.4. The code makes the grain one time from a seed, as it makes the paper in [Bristles and Paper](https://www.ziglang.in/learn/paint/bristles-and-paper/). Pigment settles faster in some cells than in others. This gives the spotted look of real watercolour, which has the name granulation.

## The page controls the clock

`step` takes no time argument. It always moves the simulation forward exactly 1/30 of a second.

The page keeps the clock. In each frame, the page adds the time since the last frame to an **accumulator**. Then it runs full steps while the accumulator holds at least 1/30 of a second:

```ts
while (accumulator >= DT && steps < MAX_STEPS_PER_FRAME) {
  e.wc_step();
  accumulator -= DT;
  steps++;
}
if (steps === MAX_STEPS_PER_FRAME) accumulator = 0;
```

If the accumulator holds 0.05 seconds, one step runs, and about 0.0167 seconds stay for the next frame.

The limit of four steps is important on a slow computer. Without the limit, a frame that took too long would need more steps. Then the next frame would take longer again. With the limit, the experiment becomes slower, and the page continues to respond.

The engine never sees a clock. Thus a test can run 600 steps without a wait, and examine exactly how much the paper dries in 20 seconds.

## The same run in all builds

The simulation uses `pow` and `exp` on `f32` values. Two builds of the same program can start to disagree at these functions.

Thus, as with the brush demo, the engine contains a fixed run: three drops and three seconds, with a fixed hash of its picture. The native tests and the self-test of the browser build both compare with that hash. If the results are different, the site does not publish.

## Checks

This test examines the cell numbers, and the neighbours at a corner and at an edge:

```zig
test "a middle cell has four neighbours, a corner two, and an edge does not wrap" {
    var w = try lab(80, 50);
    defer w.deinit(testing.allocator);
    var count: usize = 0;
    for (w.neighbours(10, 10)) |n| count += @intFromBool(n != null);
    try testing.expectEqual(@as(usize, 4), count);
    count = 0;
    for (w.neighbours(0, 0)) |n| count += @intFromBool(n != null);
    try testing.expectEqual(@as(usize, 2), count);
    // The left neighbour of (0, 5) would be index 399, the end of row 4.
    try testing.expectEqual(@as(?usize, null), w.neighbours(0, 5)[0]);
}
```

*Quoted from the source: `a middle cell has four neighbours, a corner two, and an edge does not wrap` from `examples/paint/src/engine/watercolor.zig`.*

This test is the spread example, with 0.28 and 0.18:

```zig
test "a wet centre at rate 0.18 keeps 0.28 and gives each neighbour 0.18" {
    var w = try lab(5, 5);
    defer w.deinit(testing.allocator);
    w.water[w.index(2, 2)] = 1;
    w.spread(w.water, null, .forward);
    try testing.expectApproxEqAbs(@as(f32, 0.28), w.water[w.index(2, 2)], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.18), w.water[w.index(1, 2)], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.18), w.water[w.index(2, 3)], 1e-6);
}
```

*Quoted from the source: `a wet centre at rate 0.18 keeps 0.28 and gives each neighbour 0.18` from `examples/paint/src/engine/watercolor.zig`.*

This test makes sure that a backwards scan changes nothing:

```zig
test "reading the old grid makes the scan order irrelevant" {
    var a = try lab(20, 12);
    defer a.deinit(testing.allocator);
    var b = try lab(20, 12);
    defer b.deinit(testing.allocator);
    a.drop(6, 6, 3, 1, 0);
    b.drop(6, 6, 3, 1, 0);
    for (0..10) |_| {
        a.spread(a.water, null, .forward);
        b.spread(b.water, null, .reverse);
    }
    try testing.expectEqualSlices(f32, a.water, b.water);
}
```

*Quoted from the source: `reading the old grid makes the scan order irrelevant` from `examples/paint/src/engine/watercolor.zig`.*

In this test, the paper does not dry. After 300 steps, all of the water is still there, and no value is negative:

```zig
test "spreading keeps the total and never goes negative" {
    var w = try lab(30, 20);
    defer w.deinit(testing.allocator);
    w.retention = 1; // the paper does not dry, thus all the water must stay
    w.drop(5, 5, 4, 1, 0.5);
    const water = Watercolor.total(w.water);
    for (0..300) |_| w.step();
    try testing.expectApproxEqRel(water, Watercolor.total(w.water), 1e-4);
    for (w.water) |v| try testing.expect(v >= 0);
    for (w.mobile) |v| try testing.expect(v >= 0);
}
```

*Quoted from the source: `spreading keeps the total and never goes negative` from `examples/paint/src/engine/watercolor.zig`.*

This test examines how the paper dries, with 0.8 and then 0.64:

```zig
test "drying at 0.8 a second leaves 0.8 after one second and 0.64 after two" {
    var w = try lab(3, 3);
    defer w.deinit(testing.allocator);
    @memset(w.water, 1);
    for (0..30) |_| w.step();
    try testing.expectApproxEqAbs(@as(f32, 0.8), w.water[0], 1e-4);
    for (0..30) |_| w.step();
    try testing.expectApproxEqAbs(@as(f32, 0.64), w.water[0], 1e-4);
}
```

*Quoted from the source: `drying at 0.8 a second leaves 0.8 after one second and 0.64 after two` from `examples/paint/src/engine/watercolor.zig`.*

This test makes sure that no pigment is lost when it settles:

```zig
test "settling moves pigment into the paper and loses none" {
    var w = try lab(30, 20);
    defer w.deinit(testing.allocator);
    w.drop(15, 10, 5, 1, 0.6);
    const pigment = Watercolor.total(w.mobile);
    for (0..600) |_| w.step();
    const now = Watercolor.total(w.mobile) + Watercolor.total(w.deposited);
    try testing.expectApproxEqRel(pigment, now, 1e-4);
    // After twenty seconds, almost all of the pigment is in the paper.
    try testing.expect(Watercolor.total(w.deposited) > 0.95 * pigment);
}
```

*Quoted from the source: `settling moves pigment into the paper and loses none` from `examples/paint/src/engine/watercolor.zig`.*

## Explain before you read the answer

Does `rate` 0.18 mean that real paper spreads water at a measured speed?

No, it does not. The number makes this grid act like wet paper, within the limit that keeps the rule stable. A finer grid would need a different number for the same look, because each step would move water a shorter distance. Only the units for the water that dries and the pigment that settles are real here. They are rates for each second.
