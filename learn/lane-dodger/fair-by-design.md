# Difficulty You Can Prove

> Row spacing from what is physically possible, a bot that proves that the course is solvable, and a reaction time model for playability.

The course generator puts down rows of blocks. The rows must become more
difficult, and they must stay possible.

A mistake here does not look like a bug. Each row still has an open lane and the
game still runs, but nobody can survive the course. The only sign is that people
stop their play.

## The spacing has a minimum

Between the arrival of one row and the next row, the player can have to cross
the full board. That costs two lane changes. Also, the player cannot start while
the current row is level with the player. A move to the side into a block next
to you is a crash.

The smallest spacing that a player can still survive is the sum of these two
times.

```zig
/// The smallest row spacing that a player can still survive at this speed. It
/// is the time to cross the full board, plus the time that the current row is
/// level with the player. Below this value, the game is impossible, however
/// open the rows look.
pub fn fairnessFloor(speed: f32) f32 {
    return 2 * config.lane_change_time + blockedSeconds(speed);
}
```

*Quoted from the source: `fairnessFloor` from `examples/lane-dodger/src/sim/sim.zig`.*

The second term becomes smaller when the game becomes faster, because a faster
row is next to you for less time. The first term does not change with the speed.

## Calculate the spacing, do not adjust it by hand

The first version had two constants that a person selected: an easy spacing and
a hard spacing. The game interpolated between them. This method worked. But it
had three numbers that had to agree, and nothing in the code said so. If you
changed the lane change time, the hard spacing became impossible without an
error.

Now the code calculates the spacing from the minimum, and the spacing decays
toward the minimum.

```zig
/// The seconds between rows. The value decays toward the minimum, and never
/// gets to it.
///
/// Thus the difficulty increases for as long as a person plays. The margin
/// above the impossible spacing is a named constant. It does not come by
/// chance from two endpoints that a person selected and a third number that
/// agrees with them.
pub fn rowGapSeconds(speed: f32, time: f32) f32 {
    const floor = fairnessFloor(speed) + config.gap_safety;
    const decay = std.math.exp(-time / config.gap_tau);
    if (config.row_gap_easy <= floor) return floor;
    return floor + (config.row_gap_easy - floor) * decay;
}
```

*Quoted from the source: `rowGapSeconds` from `examples/lane-dodger/src/sim/sim.zig`.*

The decay never gets to the minimum, and this fixes a second problem. The
earlier curve got to its most difficult setting at sixty seconds and then stayed
there. A sufficiently good player never lost.

One named constant now holds the margin above the impossible spacing.

```zig
/// The margin that the row spacing keeps above the point where a player can
/// no longer survive.
///
/// The physics of the game sets a minimum for the spacing. Between the arrival
/// of one row and the next row, the player must be able to cross the full
/// board (`2 * lane_change_time`). Also, the player cannot start while the
/// current row is level with the player (`2 * (player_half_h + block_half_h) / speed`).
/// If the rows are closer than that sum, no player can survive. That failure
/// would be silent, because each row would still leave a lane open. But
/// nobody could get to that lane.
///
/// Thus `sim.rowGapSeconds` calculates that minimum, adds this margin, and
/// decays toward it. The game always becomes more difficult, and it always
/// stays solvable. A designer adjusts this margin, and the margin sets only
/// the quantity of extra space. The code calculates the minimum, and the
/// minimum decides if a player can survive.
pub const gap_safety: f32 = 0.06;
```

*Quoted from the source: `gap_safety` from `examples/lane-dodger/src/sim/config.zig`.*

## Prove it with play

All of this is still an argument about four constants. That type of argument is
easy to get wrong. Thus a program plays the game.

```zig
/// The lane where the bot wants to be.
pub fn targetLane(w: *const sim.World) u8 {
    const current = w.player.lane;
    const pos = position(w);
    const view = look(w);

    var best: ?u8 = null;
    var best_cost: f32 = std.math.floatMax(f32);

    for (0..config.lane_count) |i| {
        const lane: u8 = @intCast(i);
        const lane_f: f32 = @floatFromInt(i);

        if (view.blocked_now[lane]) continue;
        if (view.next) |next| {
            if (next.blocked[lane]) continue;
        }
        if (!pathClear(pos, lane_f, view.blocked_now)) continue;

        const distance = @abs(lane_f - pos);
        const travel = distance * config.lane_change_time;
        if (view.next) |next| {
            if (travel + margin > next.seconds) continue;
        }

        var cost = distance;
        // Prefer a lane that is still good one row later. Then the bot does
        // not always have to solve the problem that it just made.
        if (view.after) |after| {
            if (after.blocked[lane]) cost += 1.5;
        }
        // Take a coin when the coin is on the path and the time is
        // sufficient. The bot limits its effort for coins. A dodge that fails
        // stops the run, but a coin that the bot does not get costs only a
        // multiplier.
        if (view.next) |next| {
            if (next.coin_lane == lane and next.seconds > travel * 2) cost -= 0.5;
        }
        if (cost < best_cost) {
            best_cost = cost;
            best = lane;
        }
    }

    // The bot cannot get to a safe lane. The spacing rule in config.zig must
    // make this impossible, and the tests check that. But if the policy
    // panicked here, a bad adjustment would crash the program.
    return best orelse current;
}
```

*Quoted from the source: `targetLane` from `examples/lane-dodger/src/sim/bot.zig`.*

The policy looks at the next two rows. It does three things:

- It selects a lane that is open in the first row.
- It does not start a move across the board that it cannot complete in time.
- It does not take a path that slides through a block that is level with it now.

Then a test runs the bot for four minutes of game time at each seed.

```zig
test "solvable course: the bot survives a long run at every seed" {
    // This test proves that the generator is fair. Four minutes is well after
    // the point where the difficulty ramp saturates. Thus the test includes the
    // smallest spacing that the game makes.
    for (0..24) |seed| {
        const w = playWithBot(seed, 240);
        std.testing.expectEqual(sim.Phase.playing, w.phase) catch |err| {
            std.debug.print(
                "seed {d}: crashed after {d:.1}s at score {d}\n",
                .{ seed, w.time, w.score },
            );
            return err;
        };
    }
}
```

*Quoted from the source: `solvable course: the bot survives a long run at every seed` from `examples/lane-dodger/src/sim/tests.zig`.*

The test failed on its first run, at seed 21, after 8.2 seconds of play.

## What the test found

The bot steered into blocks that it thought were behind it. It ignored each
block whose centre was behind the centre of the player. It measured this
distance with only the half height of the block. The correct number is the sum
of the two half heights. Each body is 52 units tall. Thus a block whose centre
is 41 units behind you still overlaps you.

```zig
/// The vertical half-span in which a block and the player overlap. A block is
/// dangerous from `+reach` in front of the player to `-reach` behind the
/// player. If this value used only the half-height of the block, the result
/// would be the off-by-one-body bug that the fairness test found.
const reach = config.player_half_h + config.block_half_h;
```

*Quoted from the source: `reach` from `examples/lane-dodger/src/sim/bot.zig`.*

The title of the regression test states the case:

```zig
test "the bot will not slide into a block that is still level with it" {
    // The regression that the fairness test found. A block whose centre is
    // behind the centre of the player can still overlap the player. If the bot
    // thinks that the block is behind it, the bot steers into the side of the
    // block.
    var w: sim.World = .init(1);
    w.start();
    w.entities.clear();
    const beside: u8 = w.player.lane + 1;
    _ = w.entities.create(.{
        .kind = .block,
        .lane = beside,
        // Behind the centre of the player, but well inside the overlap band.
        .y = config.player_y + reach * 0.8,
        .y_prev = config.player_y + reach * 0.8,
    });
    try std.testing.expect(targetLane(&w) != beside);
}
```

*Quoted from the source: `the bot will not slide into a block that is still level with it` from `examples/lane-dodger/src/sim/bot.zig`.*

Each unit test passed while this bug existed. The collision code was correct by
itself. The generator and the spacing were also correct. The error was in the
logic that connected these parts. Only a full run of the game tests that logic.

## Solvable and playable are different

A bot with no reaction time can survive a course. That result proves that the
course is solvable. It does not tell you if a person can play the course.

Thus the same policy runs again with a delay before it.

```zig
/// A player who sees the danger and then needs a moment to act. The model
/// contains only latency. The player acts now on the decision from the world
/// as it was `delay` ticks ago.
///
/// With this model, the tests can tell you something about whether the game
/// is *fun*. The bot proves that the course is solvable. But the bot has no
/// reaction time, and a course that only a machine can pass is not a game.
/// With a delay before the same policy, the test asks if the game is fair to a
/// person.
const Human = struct {
    delay: usize,
    buffer: [64]u8 = @splat(config.lane_count / 2),
    index: usize = 0,

    fn init(reaction_seconds: f32) Human {
        return .{ .delay = @intFromFloat(reaction_seconds * config.tick_hz) };
    }

    fn play(self: *Human, w: *const World) Input {
        self.buffer[self.index % self.buffer.len] = bot.targetLane(w);
        const decided = self.buffer[(self.index + self.buffer.len - self.delay) % self.buffer.len];
        self.index += 1;
        if (decided < w.player.lane) return .{ .left = true };
        if (decided > w.player.lane) return .{ .right = true };
        return .none;
    }
};
```

*Quoted from the source: `Human` from `examples/lane-dodger/src/sim/tests.zig`.*

The model contains only latency. The bot acts now on the decision that it made
from the world as the world was some ticks ago. An earlier version counted down a
timer and reset the timer each time that the ideal lane changed. When the policy
could not choose between two lanes, that version livelocked. The model reported
that the game was much more difficult than it really was. Some time passed
before anybody saw that the fault was in the model and not in the game.

The numbers from the model are the difficulty curve:

| Reaction | Mean run |
| --- | --- |
| 100 ms | 58 s |
| 150 ms | 46 s |
| 200 ms | 30 s |
| 250 ms | 26 s |
| 300 ms | 24 s |

Thus a slow, calm player gets half a minute, and a fast player gets a minute. All
players lose at some time. That part took the most work.

The test asserts the shape and not the values. Thus you can adjust the numbers
and not rewrite the test.

```zig
test "a run lasts about as long as a hyper casual run should" {
    // A quarter second is a slow, calm player. That player must get a real
    // run, and not a game over screen after a few seconds.
    const casual = meanSurvival(0.25, 24, 300);
    std.testing.expect(casual > 12 and casual < 70) catch |err| {
        std.debug.print("casual player averaged {d:.1}s\n", .{casual});
        return err;
    };

    // A fast player must last longer. If not, skill makes no difference.
    const sharp = meanSurvival(0.10, 24, 300);
    std.testing.expect(sharp > casual * 1.5) catch |err| {
        std.debug.print("sharp {d:.1}s vs casual {d:.1}s\n", .{ sharp, casual });
        return err;
    };

    // A fast player must still lose. This check finds the difficulty curve
    // that saturated, where a fast player never died.
    std.testing.expect(sharp < 180) catch |err| {
        std.debug.print("sharp player averaged {d:.1}s: the game stops getting harder\n", .{sharp});
        return err;
    };
}
```

*Quoted from the source: `a run lasts about as long as a hyper casual run should` from `examples/lane-dodger/src/sim/tests.zig`.*

The last assertion found the flat difficulty curve. A fast player had an average
of the full limit of three hundred seconds, and every other test passed.

## Two smaller rules

**The start is easy.** During a grace window, no row blocks more than one lane.
In the first few seconds, one small move is sufficient for each row.

This rule is a decision, not a measurement. The reaction time model already
knows the controls perfectly. Thus the model cannot show the problems of a
player who still looks for the keys. When the window is off, the modelled 200 ms
average moves by three tenths of a second.

```zig
/// The seconds at the start when no row blocks more than one lane.
///
/// This value is a decision, not a measurement. The reaction time model in the
/// tests already knows the controls. Thus the model cannot show a new player
/// who still looks for the keys. When the window is off, the modelled 200 ms
/// average moves from 29.5 s to 29.2 s. In the grace window, each row leaves
/// two lanes open. Thus one lane change is always sufficient to pass the row.
pub const grace_seconds: f32 = 7;
```

*Quoted from the source: `grace_seconds` from `examples/lane-dodger/src/sim/config.zig`.*

**Coins show the safe lane.** The spawner puts a coin only in a lane that its own
row leaves open. When a row blocks two of the three lanes, the coin is in the one
gap. A player who follows the coins follows the safe path, and nobody has to tell
the player. The rule is four statements in the spawner. The game has no other
tutorial.

```zig
    fn spawnRow(w: *World) void {
        const d = w.difficulty();

        // Shuffle the lanes, then block a prefix of them. Because the code
        // blocks a prefix of a shuffle, the blocked lanes are always
        // different. The count is always less than `lane_count`. Thus a free
        // lane always remains.
        var lanes: [config.lane_count]u8 = undefined;
        for (&lanes, 0..) |*lane, i| lane.* = @intCast(i);
        var i: usize = lanes.len;
        while (i > 1) {
            i -= 1;
            const j = w.rng.below(@intCast(i + 1));
            std.mem.swap(u8, &lanes[i], &lanes[j]);
        }

        const two = w.time > config.grace_seconds and w.rng.chance(lerp(
            config.two_block_chance_easy,
            config.two_block_chance_hard,
            d,
        ));
        const blocked: usize = if (two) 2 else 1;
        std.debug.assert(blocked <= config.max_blocked_lanes);

        for (lanes[0..blocked]) |lane| {
            _ = w.entities.create(.{
                .kind = .block,
                .lane = lane,
                .y = config.spawn_y,
                .y_prev = config.spawn_y,
            });
        }

        // The coin goes in a lane that this row leaves open. This keeps the
        // row fair, and it also teaches the player. When a row blocks two of
        // three lanes, the coin is in the one gap. Thus, if the player follows
        // the coins, the player plays correctly.
        const free = lanes[blocked..];
        if (free.len > 0 and w.rng.chance(config.coin_chance)) {
            const lane = free[w.rng.below(@intCast(free.len))];
            _ = w.entities.create(.{
                .kind = .coin,
                .lane = lane,
                .y = config.spawn_y,
                .y_prev = config.spawn_y,
            });
        }
    }
```

*Quoted from the source: `spawnRow` from `examples/lane-dodger/src/sim/sim.zig`.*
