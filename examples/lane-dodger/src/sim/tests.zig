//! Gameplay tests. These play the game; none of them opens a window.

const std = @import("std");
const sim = @import("sim.zig");
const bot = @import("bot.zig");
const config = @import("config.zig");

const World = sim.World;
const Input = sim.Input;

/// Run the bot for `seconds` of simulated time, checking invariants every tick.
/// Returns the world so the caller can assert on the outcome.
fn playWithBot(seed: u64, seconds: f32) World {
    var w: World = .init(seed);
    w.start();
    const ticks: usize = @intFromFloat(seconds * config.tick_hz);
    for (0..ticks) |_| {
        w.step(bot.play(&w));
        w.events.reset();
    }
    return w;
}

/// A player who sees the threat, then takes a moment to act on it, modelled as
/// pure latency: the decision made from the world as it looked `delay` ticks
/// ago is the one acted on now.
///
/// This is the only way the tests can say anything about whether the game is
/// *fun*. The bot proves the course is solvable, but it is solvable by
/// something with no reaction time at all, and a course only a machine can run
/// is not a game. Putting a delay in front of the same policy turns "is this
/// fair" into "is this fair to a person".
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

/// Mean seconds survived by a player with this reaction time.
fn meanSurvival(reaction_seconds: f32, seeds: usize, cap: f32) f32 {
    var total: f32 = 0;
    for (0..seeds) |seed| {
        var w: World = .init(seed);
        w.start();
        var human: Human = .init(reaction_seconds);
        while (w.phase == .playing and w.time < cap) {
            w.step(human.play(&w));
            w.events.reset();
        }
        total += w.time;
    }
    return total / @as(f32, @floatFromInt(seeds));
}

test "a run lasts about as long as a hyper casual run should" {
    // A quarter second is an unhurried player. They should get a real go at it,
    // not four seconds and a game over screen.
    const casual = meanSurvival(0.25, 24, 300);
    std.testing.expect(casual > 12 and casual < 70) catch |err| {
        std.debug.print("casual player averaged {d:.1}s\n", .{casual});
        return err;
    };

    // A sharp player must last longer, or there is no skill in it.
    const sharp = meanSurvival(0.10, 24, 300);
    std.testing.expect(sharp > casual * 1.5) catch |err| {
        std.debug.print("sharp {d:.1}s vs casual {d:.1}s\n", .{ sharp, casual });
        return err;
    };

    // And must still lose. This is the test that would have caught the
    // saturating difficulty curve, where a sharp player simply never died.
    std.testing.expect(sharp < 180) catch |err| {
        std.debug.print("sharp player averaged {d:.1}s: the game stops getting harder\n", .{sharp});
        return err;
    };
}

test "the row spacing never falls to the unwinnable floor" {
    // Not just on the ramp: for an hour of play. The spacing decays towards
    // the floor and must never touch it, or the game would become impossible
    // while still looking perfectly reasonable, every row leaving a lane open
    // that nobody could reach in time.
    var t: f32 = 0;
    while (t <= 3600) : (t += 0.5) {
        const speed = sim.speedAt(t);
        const gap = sim.rowGapSeconds(speed, t);
        const floor = sim.fairnessFloor(speed);
        std.testing.expect(gap >= floor + config.gap_safety) catch |err| {
            std.debug.print(
                "t={d:.1}s: gap {d:.4}s, floor {d:.4}s, margin {d:.4}s\n",
                .{ t, gap, floor, gap - floor },
            );
            return err;
        };
    }
}

test "the game keeps getting harder for as long as anyone can survive it" {
    // An endless runner whose difficulty plateaus is one a good player never
    // loses, and a score nobody can lose measures patience rather than skill.
    //
    // The spacing does eventually stop moving, at around eight minutes, when
    // the decaying term drops below the last bit of an f32 near the floor. That
    // is far outside what the reaction time test below says a person reaches,
    // so the plateau is real but unreachable. What matters is that it is a
    // plateau at the hardest setting rather than partway up.
    var previous = sim.rowGapSeconds(sim.speedAt(0), 0);
    var t: f32 = 1;
    while (t <= 600) : (t += 1) {
        const gap = sim.rowGapSeconds(sim.speedAt(t), t);
        try std.testing.expect(gap <= previous);
        previous = gap;
    }

    // Strictly harder across the range a run can actually last.
    var sample: f32 = 0;
    while (sample < 240) : (sample += 10) {
        const now = sim.rowGapSeconds(sim.speedAt(sample), sample);
        const later = sim.rowGapSeconds(sim.speedAt(sample + 10), sample + 10);
        try std.testing.expect(later < now);
    }

    // And meaningfully harder late than early, not merely different.
    const early = sim.rowGapSeconds(sim.speedAt(0), 0);
    const late = sim.rowGapSeconds(sim.speedAt(300), 300);
    try std.testing.expect(late < early * 0.6);
}

test "the opening never demands a two lane crossing" {
    // A first-time player has not learned the controls yet. Inside the grace
    // window every row leaves two lanes open, so one nudge in either direction
    // always answers it.
    for (0..32) |seed| {
        var w: World = .init(seed);
        w.start();
        while (w.time < config.grace_seconds) {
            w.step(bot.play(&w));
            w.events.reset();

            var rows: [config.lane_count * 16]struct { y: f32, lanes: u8 } = undefined;
            var count: usize = 0;
            var it = w.entities.iterator();
            outer: while (it.next()) |entry| {
                const e = entry.value;
                if (e.kind != .block) continue;
                for (rows[0..count]) |*row| {
                    if (row.y == e.y) {
                        row.lanes += 1;
                        try std.testing.expectEqual(@as(u8, 1), row.lanes);
                        continue :outer;
                    }
                }
                rows[count] = .{ .y = e.y, .lanes = 1 };
                count += 1;
            }
        }
    }
}

test "a row never blocks every lane" {
    for (0..16) |seed| {
        var w: World = .init(seed);
        w.start();
        for (0..30_000) |_| {
            w.step(bot.play(&w));
            w.events.reset();

            // Blocks laid down together share a y exactly, and advance by the
            // same amount every tick, so grouping on y recovers the rows.
            var rows: [config.lane_count * 16]struct { y: f32, lanes: u8 } = undefined;
            var count: usize = 0;
            var it = w.entities.iterator();
            outer: while (it.next()) |entry| {
                const e = entry.value;
                if (e.kind != .block) continue;
                for (rows[0..count]) |*row| {
                    if (row.y == e.y) {
                        row.lanes += 1;
                        try std.testing.expect(row.lanes < config.lane_count);
                        continue :outer;
                    }
                }
                rows[count] = .{ .y = e.y, .lanes = 1 };
                count += 1;
            }
        }
    }
}

test "solvable course: the bot survives a long run at every seed" {
    // The real proof that the generator is fair. Four minutes is well past the
    // point where the difficulty ramp saturates, so this covers the hardest
    // spacing the game ever produces.
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

test "a competent run scores, collects and reaches full speed" {
    // The numbers are measured from the bot, not guessed. They are a floor: if
    // a change to the tuning halves the scoring rate or stalls the ramp, this
    // notices, without pinning the exact values a designer is allowed to move.
    const w = playWithBot(7, 90);
    try std.testing.expect(w.time > 89);
    try std.testing.expectApproxEqAbs(config.speed_max, w.speed(), 0.001);
    try std.testing.expect(w.distance > 40_000);
    try std.testing.expect(w.coins > 40);
    try std.testing.expect(w.score > 7_000);
}

test "the near miss band is reachable, and is not just \"a block went by\"" {
    // Below the collision width it is a crash; at a full lane it would fire on
    // every block that passes in the next lane over.
    try std.testing.expect(config.near_miss_dist > config.player_half_w + config.block_half_w);
    try std.testing.expect(config.near_miss_dist < config.lane_w);
}

test "the entity pool and event buffer never overflow" {
    for (0..8) |seed| {
        var w: World = .init(seed);
        w.start();
        var peak: u16 = 0;
        for (0..40_000) |_| {
            w.step(bot.play(&w));
            peak = @max(peak, w.entities.live);
            try std.testing.expectEqual(@as(usize, 0), w.events.dropped);
            w.events.reset();
        }
        // Headroom, but not so much that the array is silly.
        try std.testing.expect(peak < sim.EntityPool.capacity);
        try std.testing.expect(peak > 6);
    }
}

test "replay: the same seed and inputs produce an identical run" {
    // Determinism is what makes a crash reportable as a seed and a keylog
    // rather than a video, and it is the reason step() takes no dt.
    const script = struct {
        fn inputAt(tick: usize) Input {
            return switch (tick % 37) {
                5 => .{ .left = true },
                11 => .{ .right = true },
                23 => .{ .right = true },
                31 => .{ .left = true },
                else => .none,
            };
        }
    };

    var a: World = .init(0xC0FFEE);
    var b: World = .init(0xC0FFEE);
    a.start();
    b.start();
    for (0..20_000) |tick| {
        const input = script.inputAt(tick);
        a.step(input);
        b.step(input);
        a.events.reset();
        b.events.reset();
        try std.testing.expectEqual(a.phase, b.phase);
        try std.testing.expectEqual(a.score, b.score);
        try std.testing.expectEqual(a.player.lane, b.player.lane);
        try std.testing.expectEqual(a.player.x, b.player.x);
        try std.testing.expectEqual(a.entities.live, b.entities.live);
    }
    // And the script actually exercised the game rather than idling.
    try std.testing.expect(a.phase == .dead or a.score > 0);
}

test "different seeds produce different courses" {
    const a = playWithBot(1, 20);
    const b = playWithBot(2, 20);
    try std.testing.expect(a.coins != b.coins or a.score != b.score);
}

test "the player never leaves the field" {
    var w: World = .init(42);
    w.start();
    for (0..20_000) |tick| {
        // Lean on one wall, then the other, harder than a human could.
        w.step(if (tick % 400 < 200) .{ .left = true } else .{ .right = true });
        w.events.reset();
        try std.testing.expect(w.player.lane < config.lane_count);
        try std.testing.expect(w.player.x >= config.laneCenter(0) - 0.001);
        try std.testing.expect(w.player.x <= config.laneCenter(config.lane_count - 1) + 0.001);
        if (w.phase == .dead) w.step(.{ .confirm = true });
    }
}

test "a held direction moves exactly one lane" {
    // Input is edge-triggered. If a held key were read as a press every tick,
    // the player would cross the board in two frames.
    var w: World = .init(1);
    w.start();
    const start_lane = w.player.lane;
    w.step(.{ .right = true });
    try std.testing.expectEqual(start_lane + 1, w.player.lane);
    for (0..60) |_| w.step(.none);
    try std.testing.expectEqual(start_lane + 1, w.player.lane);
}

test "a lane change takes the time it is supposed to" {
    var w: World = .init(1);
    w.start();
    w.entities.clear();
    const from = config.laneCenter(w.player.lane);
    w.step(.{ .right = true });
    const target = config.laneCenter(w.player.lane);
    try std.testing.expect(target != from);

    var ticks: usize = 1;
    while (@abs(w.player.x - target) > 0.01 and ticks < 1000) : (ticks += 1) {
        w.entities.clear(); // keep the run alive; we are timing the slide
        w.step(.none);
    }
    const elapsed = @as(f32, @floatFromInt(ticks)) * config.tick_dt;
    try std.testing.expectApproxEqAbs(config.lane_change_time, elapsed, config.tick_dt * 2);
}

test "hitting a block ends the run and restarting clears the field" {
    var w: World = .init(3);
    w.start();
    w.entities.clear();
    _ = w.entities.create(.{
        .kind = .block,
        .lane = w.player.lane,
        .y = config.player_y - 40,
        .y_prev = config.player_y - 40,
    });
    var guard: usize = 0;
    while (w.phase == .playing and guard < 1000) : (guard += 1) w.step(.none);
    try std.testing.expectEqual(sim.Phase.dead, w.phase);

    // A restart is refused until the crash has played out.
    w.events.reset();
    w.step(.{ .confirm = true });
    try std.testing.expectEqual(sim.Phase.dead, w.phase);

    var held: f32 = 0;
    while (held < config.death_hold) : (held += config.tick_dt) w.step(.none);
    w.step(.{ .confirm = true });
    try std.testing.expectEqual(sim.Phase.playing, w.phase);
    try std.testing.expectEqual(@as(u32, 0), w.score);
    try std.testing.expectEqual(@as(f32, 0), w.time);
}

test "the best score survives a restart" {
    var w: World = .init(5);
    w.start();
    for (0..2_000) |_| {
        w.step(bot.play(&w));
        w.events.reset();
    }
    const best = w.best;
    try std.testing.expect(best > 0);
    w.start();
    try std.testing.expectEqual(@as(u32, 0), w.score);
    try std.testing.expectEqual(best, w.best);
}

test "a coin pays the combo multiplier, and a miss resets it" {
    var w: World = .init(9);
    w.start();
    w.entities.clear();

    // Drop three coins onto the player, one at a time.
    for (1..4) |expected_combo| {
        _ = w.entities.create(.{
            .kind = .coin,
            .lane = w.player.lane,
            .y = config.player_y - 30,
            .y_prev = config.player_y - 30,
        });
        var guard: usize = 0;
        while (w.coins < expected_combo and guard < 500) : (guard += 1) w.step(.none);
        try std.testing.expectEqual(@as(u32, @intCast(expected_combo)), w.combo);
    }
    const bonus_after_three = w.bonus;
    // 25*1 + 25*2 + 25*3
    try std.testing.expectEqual(config.coin_points * 6, bonus_after_three);

    // Now let one fall past.
    _ = w.entities.create(.{
        .kind = .coin,
        .lane = (w.player.lane + 1) % config.lane_count,
        .y = config.player_y - 30,
        .y_prev = config.player_y - 30,
    });
    var guard: usize = 0;
    while (w.combo != 0 and guard < 2000) : (guard += 1) w.step(.none);
    try std.testing.expectEqual(@as(u32, 0), w.combo);
    try std.testing.expectEqual(bonus_after_three, w.bonus);
}

test "the combo multiplier is capped" {
    var w: World = .init(11);
    w.start();
    w.entities.clear();
    for (0..config.max_combo + 10) |_| {
        _ = w.entities.create(.{
            .kind = .coin,
            .lane = w.player.lane,
            .y = config.player_y - 30,
            .y_prev = config.player_y - 30,
        });
        var guard: usize = 0;
        while (w.entities.live > 0 and guard < 500) : (guard += 1) w.step(.none);
    }
    try std.testing.expectEqual(config.max_combo, w.combo);
}

test "events are emitted for the things the renderer reacts to" {
    var w: World = .init(13);
    w.start();
    w.entities.clear();
    w.events.reset();

    w.step(.{ .right = true });
    var saw_lane_change = false;
    for (w.events.slice()) |event| {
        if (event == .lane_changed) saw_lane_change = true;
    }
    try std.testing.expect(saw_lane_change);

    // A block that draws level while the player is still partly in its lane is
    // a near miss. That means catching the player mid-slide, so put them there
    // directly rather than trying to time a keypress.
    w.events.reset();
    w.entities.clear();
    const vacating: u8 = 1;
    w.player = .{
        .lane = 2,
        // Clear of the block's edge, inside the near miss band.
        .x = config.laneCenter(vacating) + config.player_half_w + config.block_half_w + 12,
        .x_prev = 0,
    };
    _ = w.entities.create(.{
        .kind = .block,
        .lane = vacating,
        .y = config.player_y - 1,
        .y_prev = config.player_y - 1,
    });
    w.step(.none);
    try std.testing.expectEqual(sim.Phase.playing, w.phase); // grazed, not hit

    var saw_near_miss = false;
    for (w.events.slice()) |event| {
        if (event == .near_miss) saw_near_miss = true;
    }
    try std.testing.expect(saw_near_miss);
}

test "the first row is never close enough to be unavoidable" {
    for (0..64) |seed| {
        var w: World = .init(seed);
        w.start();
        // The player must have at least a full board crossing before the first
        // block is level with them, whatever lane it lands in.
        var ticks: usize = 0;
        while (w.entities.live == 0) : (ticks += 1) w.step(.none);
        var nearest: f32 = std.math.floatMax(f32);
        var it = w.entities.iterator();
        while (it.next()) |entry| nearest = @min(nearest, config.player_y - entry.value.y);
        const seconds = nearest / w.speed();
        try std.testing.expect(seconds > 2 * config.lane_change_time);
    }
}

test "speed rises monotonically and then holds" {
    var previous: f32 = 0;
    var t: f32 = 0;
    while (t < config.ramp_seconds * 2) : (t += 0.25) {
        const speed = sim.speedAt(t);
        try std.testing.expect(speed >= previous);
        try std.testing.expect(speed <= config.speed_max);
        previous = speed;
    }
    try std.testing.expectApproxEqAbs(config.speed_start, sim.speedAt(0), 0.001);
    try std.testing.expectApproxEqAbs(config.speed_max, sim.speedAt(config.ramp_seconds), 0.001);
}
