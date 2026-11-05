# The World

> A field with its own units, a player that slides between lanes, and the order of the work in a tick.

The simulation never uses pixels. It uses a fixed field of 360 by 640 units. The
renderer maps the field onto the window, whatever the size of the window.

```zig
/// The play field, in simulation units. The field is portrait, because the
/// player uses a thumb to play.
pub const field_w: f32 = 360;
```

*Quoted from the source: `field_w` from `examples/lane-dodger/src/sim/config.zig`.*

This design has two results:

- A change to the size of the window cannot change the difficulty, because a
  wider window does not show more road.
- A test can assert that a block is at `y = 520`, and the test opens nothing.

The three lanes divide the width. Thus a lane is 120 units wide.

```zig
/// The centre of a lane, in field units.
pub fn laneCenter(lane: u8) f32 {
    return (@as(f32, @floatFromInt(lane)) + 0.5) * lane_w;
}
```

*Quoted from the source: `laneCenter` from `examples/lane-dodger/src/sim/config.zig`.*

Thus `laneCenter(0)` is 60, `laneCenter(1)` is 180 and `laneCenter(2)` is 300.
These three numbers are the only x positions where an object stops.

The player is at a fixed height near the bottom. The world moves toward the
player.

```zig
/// The player is at a fixed height, and the world moves toward the player.
pub const player_y: f32 = 520;
```

*Quoted from the source: `player_y` from `examples/lane-dodger/src/sim/config.zig`.*

## The player has two positions

One position is the lane that the player steers toward. The other position is
where the body of the player really is.

```zig
pub const Player = struct {
    /// The lane that the player steers toward. It changes immediately when the
    /// player presses a key.
    lane: u8,
    /// Where the player really is. It slides toward the lane centre. Thus the
    /// player can change direction during a slide. Also, if the player touches
    /// a block during a slide, the result is a real crash.
    x: f32,
    x_prev: f32,
};
```

*Quoted from the source: `Player` from `examples/lane-dodger/src/sim/sim.zig`.*

`lane` changes immediately when the player presses a key. `x` slides toward the
centre of that lane during `lane_change_time`. After each press, the two values
are different for approximately a tenth of a second. That difference gives the
game its feel.

```zig
/// The seconds for a slide of one full lane. This number has a large effect on
/// how the controls feel. If it is too slow, the game is unfair. If it is
/// too fast, a lane change costs nothing to cancel.
pub const lane_change_time: f32 = 0.11;
```

*Quoted from the source: `lane_change_time` from `examples/lane-dodger/src/sim/config.zig`.*

The slide has a constant speed. It does not start slowly or stop slowly.

```zig
    fn movePlayer(w: *World, dt: f32) void {
        w.player.x_prev = w.player.x;
        const target = config.laneCenter(w.player.lane);
        // A constant speed, and not a slow start and stop. Thus two lanes cost
        // exactly two times one lane. The fairness budget in config.zig needs
        // that.
        const rate = config.lane_w / config.lane_change_time;
        const delta = target - w.player.x;
        const max_move = rate * dt;
        w.player.x += std.math.clamp(delta, -max_move, max_move);
    }
```

*Quoted from the source: `movePlayer` from `examples/lane-dodger/src/sim/sim.zig`.*

A slide that starts and stops slowly looks smoother. But with that slide, a move
of two lanes costs less than two times a move of one lane.
[The spacing rule](https://www.ziglang.in/learn/lane-dodger/fair-by-design/) needs a move of two lanes
to cost exactly two times a move of one lane. A constant speed looks less smooth,
but it keeps the spacing rule correct.

Because `x` is continuous, the player really occupies the space between lanes.
If the player touches a block during a slide, the game counts a crash.

## The other objects in the field

Blocks and coins have the same shape of data. A tag tells them apart.

```zig
pub const Entity = struct {
    kind: Kind,
    lane: u8,
    y: f32,
    /// The position at the end of the previous tick. Thus the renderer can
    /// interpolate between ticks, and does not show the steps of the
    /// simulation.
    y_prev: f32,
    /// For blocks: true when this block became level with the player. A near
    /// miss gives points one time, on the tick when it occurs.
    passed: bool = false,
};
```

*Quoted from the source: `Entity` from `examples/lane-dodger/src/sim/sim.zig`.*

`y_prev` is not simulation state. The renderer needs it to
[draw between two ticks](https://www.ziglang.in/learn/lane-dodger/the-loop/).

## The world

```zig
pub const World = struct {
    phase: Phase,
    rng: Rng,
    seed: u64,

    entities: EntityPool,
    player: Player,
    events: EventBuffer,

    /// The seconds of play in the current run.
    time: f32,
    /// The units that the world moved in the current run.
    distance: f32,
    /// The units until the game puts down the next row.
    to_next_row: f32,
    /// The seconds since the crash.
    death_time: f32,

    score: u32,
    /// The score from coins and near misses. The code calculates the distance
    /// score from `distance`. Thus rounding cannot make the total drift.
    bonus: u32,
    combo: u32,
    coins: u32,
    best: u32,

    // ...
};
```

*Quoted from the source: `World` (fields only) from `examples/lane-dodger/src/sim/sim.zig`.*

`seed` and `best` stay after a restart. The restart clears all other fields. The
game calculates `score` again on each tick, and does not add to it. The distance
points come from `distance` on each tick. Only coins and near misses add to
`bonus`. If the game added a fraction of a point 120 times each second, the
total would drift.

## The order in a tick

```zig
    fn stepPlaying(w: *World, input: Input) void {
        const dt = config.tick_dt;

        w.steer(input);
        w.movePlayer(dt);

        const moved = w.speed() * dt;
        w.advanceEntities(moved);
        w.spawnIfDue(moved);
        w.collide();

        w.distance += moved;
        w.time += dt;
        w.score = w.bonus + @as(u32, @intFromFloat(w.distance * config.points_per_unit));
        if (w.score > w.best) w.best = w.score;
    }
```

*Quoted from the source: `stepPlaying` from `examples/lane-dodger/src/sim/sim.zig`.*

A tick does these steps:

1. If a press arrived, move the target lane.
2. Slide `x` toward that lane at a constant speed.
3. Move each entity down by `speed * dt`.
4. When a block first gets to the height of the player, give points for a near
   miss.
5. Destroy each object below the field. A coin that the player did not collect
   sets the combo to zero.
6. If the world moved the full gap, spawn a row.
7. Test the box of the player against the box of each entity.
8. Calculate the score again as the bonus plus the distance.

The order has a reason. First the player moves, then the world moves, then the
tick tests the player against the world. If the tick tested collisions before
the world moved, a block could move through the player on the tick when the
block arrives.

`steer` reads the input and moves the target lane by one.

```zig
    fn steer(w: *World, input: Input) void {
        const from = w.player.lane;
        var lane: i32 = from;
        if (input.left) lane -= 1;
        if (input.right) lane += 1;
        const clamped: u8 = @intCast(std.math.clamp(lane, 0, config.lane_count - 1));
        if (clamped != from) {
            w.player.lane = clamped;
            w.events.push(.{ .lane_changed = .{ .from = from, .to = clamped } });
        }
    }
```

*Quoted from the source: `steer` from `examples/lane-dodger/src/sim/sim.zig`.*

One press moves the target one lane. The clamp keeps the player on the board. Two
fast presses set a target that is two lanes away. Then `movePlayer` slides there
continuously.

## Collision

```zig
    fn collide(w: *World) void {
        var it = w.entities.iterator();
        while (it.next()) |entry| {
            const e = entry.value;
            const ex = config.laneCenter(e.lane);
            switch (e.kind) {
                .block => {
                    if (overlaps(
                        w.player.x,
                        config.player_y,
                        config.player_half_w,
                        config.player_half_h,
                        ex,
                        e.y,
                        config.block_half_w,
                        config.block_half_h,
                    )) {
                        w.phase = .dead;
                        w.death_time = 0;
                        w.combo = 0;
                        w.events.push(.{ .crashed = .{ .x = w.player.x, .y = config.player_y } });
                        return;
                    }
                },
                .coin => {
                    if (overlaps(
                        w.player.x,
                        config.player_y,
                        config.player_half_w,
                        config.player_half_h,
                        ex,
                        e.y,
                        config.coin_half,
                        config.coin_half,
                    )) {
                        if (w.combo < config.max_combo) w.combo += 1;
                        const points = config.coin_points * w.combo;
                        w.bonus += points;
                        w.coins += 1;
                        w.events.push(.{ .coin = .{
                            .x = ex,
                            .y = e.y,
                            .combo = w.combo,
                            .points = points,
                        } });
                        w.entities.destroy(entry.handle);
                    }
                },
            }
        }
    }
```

*Quoted from the source: `collide` from `examples/lane-dodger/src/sim/sim.zig`.*

Both tests look for an overlap of two boxes whose sides are parallel to the
axes.

```zig
fn overlaps(
    ax: f32,
    ay: f32,
    ahw: f32,
    ahh: f32,
    bx: f32,
    by: f32,
    bhw: f32,
    bhh: f32,
) bool {
    return @abs(ax - bx) < ahw + bhw and @abs(ay - by) < ahh + bhh;
}
```

*Quoted from the source: `overlaps` from `examples/lane-dodger/src/sim/sim.zig`.*

A block stops the run. A coin adds to the combo, gives points, and the game
destroys the coin. The combo has a maximum. The combo goes to zero when a coin
falls off the bottom and the player did not collect it.

## The game has its own random numbers

The world has its own generator.

```zig
pub fn next(self: *Rng) u32 {
    const old = self.state;
    self.state = old *% 6364136223846793005 +% self.inc;
    const xorshifted: u32 = @truncate(((old >> 18) ^ old) >> 27);
    const rot: u5 = @truncate(old >> 59);
    return std.math.rotr(u32, xorshifted, rot);
}
```

*Quoted from the source: `next` from `examples/lane-dodger/src/sim/rng.zig`.*

The generator is thirty lines of PCG32, and not a call into the standard
library. The reason is reproducibility. A seed and a list of inputs must replay
to the identical run. Then the replay test can assert exact scores. A player
can report a bad run as a seed and not as a video. The standard library can
change the algorithm of its generators between releases, and this guide tracks
Zig master.

Each run moves the stream forward and does not use the seed again. Thus the
second game of a session is not a replay of the first game.
