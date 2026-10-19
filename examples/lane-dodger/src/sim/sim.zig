//! The rules of the game, and nothing else.
//!
//! This module imports no graphics, no window, no clock and no allocator. It is
//! a pure function from (seed, sequence of inputs) to (sequence of states).
//! That is the full design. Each test in this file plays the real game, and no
//! test opens a window. The renderer in `src/render` reads this state and
//! draws it. The renderer can do this at any frame rate, or not at all.
//!
//! For the same reason, the networking chapters of this guide parse from a
//! `Reader` and not from a socket. If you can test a rule only when you run
//! the full program, you will not test that rule.

const std = @import("std");

pub const config = @import("config.zig");
pub const Rng = @import("rng.zig");
pub const bot = @import("bot.zig");
const pool = @import("pool.zig");

/// This module exports the pool again, because the pool is not specific to the
/// simulation. The renderer keeps its particles in a pool, and particles are
/// not part of the simulation.
pub const Pool = pool.Pool;

pub const Kind = enum { block, coin };

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

/// 48 slots are much more than the field can hold. At the smallest row
/// spacing and the highest speed, about 9 rows are on the screen. Each row has
/// a maximum of 3 entities.
pub const EntityPool = pool.Pool(Entity, 48);
pub const Handle = EntityPool.Handle;

pub const Phase = enum {
    /// The title screen. The game waits for the first input.
    ready,
    playing,
    /// After a crash. The world continues to move slowly. Thus the crash looks
    /// like an event and not like a freeze. But the player cannot steer now.
    dead,
};

/// Edge-triggered: each field means "pressed during this tick", not "held".
/// A key that the player holds must not slide the player across the board.
pub const Input = struct {
    left: bool = false,
    right: bool = false,
    confirm: bool = false,

    pub const none: Input = .{};
};

/// What the simulation did in this tick. The parts of the program that react
/// to it read this: particles, screen shake, sound. The simulation does not
/// know that those parts exist. Thus a new sound cannot change the physics.
pub const Event = union(enum) {
    started,
    lane_changed: struct { from: u8, to: u8 },
    coin: struct { x: f32, y: f32, combo: u32, points: u32 },
    coin_missed,
    near_miss: struct { x: f32, y: f32 },
    crashed: struct { x: f32, y: f32 },
};

pub const EventBuffer = struct {
    items: [32]Event = undefined,
    len: usize = 0,
    /// The events that a full buffer lost. In practice, this count is always
    /// zero. The tests assert it, because a lost event gives no error. The
    /// only symptom would be some particles that do not appear.
    dropped: usize = 0,

    pub fn push(self: *EventBuffer, event: Event) void {
        if (self.len == self.items.len) {
            self.dropped += 1;
            return;
        }
        self.items[self.len] = event;
        self.len += 1;
    }

    pub fn slice(self: *const EventBuffer) []const Event {
        return self.items[0..self.len];
    }

    pub fn reset(self: *EventBuffer) void {
        self.len = 0;
    }
};

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

    pub fn init(seed: u64) World {
        var w: World = .{
            .phase = .ready,
            .rng = .init(seed, 0),
            .seed = seed,
            .entities = .empty,
            .player = undefined,
            .events = .{},
            .time = 0,
            .distance = 0,
            .to_next_row = 0,
            .death_time = 0,
            .score = 0,
            .bonus = 0,
            .combo = 0,
            .coins = 0,
            .best = 0,
        };
        w.resetRun();
        w.phase = .ready;
        return w;
    }

    /// Clear the field and start a run. `best` and `seed` do not change.
    fn resetRun(w: *World) void {
        const start_lane: u8 = config.lane_count / 2;
        w.entities.clear();
        w.player = .{
            .lane = start_lane,
            .x = config.laneCenter(start_lane),
            .x_prev = config.laneCenter(start_lane),
        };
        w.time = 0;
        w.distance = 0;
        w.death_time = 0;
        w.score = 0;
        w.bonus = 0;
        w.combo = 0;
        w.coins = 0;
        w.to_next_row = config.speed_start * config.opening_lead;
        w.phase = .playing;
    }

    pub fn start(w: *World) void {
        // A new run moves the stream forward, and does not use the seed again.
        // Thus the second run of a session is not a replay of the first run.
        w.rng = .init(w.seed, w.rng.next());
        w.resetRun();
        w.events.push(.started);
    }

    /// Move the world forward by one fixed tick.
    ///
    /// This function has no `dt` parameter, on purpose. With a variable
    /// timestep, the same inputs would give different runs on different
    /// machines. Then the replay tests below could not work. Also, in a game
    /// that gives points for survival time, a slow frame would become an
    /// advantage. The caller collects real time and calls this function a
    /// whole number of times. `src/main.zig` shows how.
    pub fn step(w: *World, input: Input) void {
        switch (w.phase) {
            .ready => if (input.confirm) w.start(),
            .playing => w.stepPlaying(input),
            .dead => {
                w.death_time += config.tick_dt;
                w.player.x_prev = w.player.x;
                w.driftEntities();
                if (w.death_time >= config.death_hold and input.confirm) w.start();
            },
        }
    }

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

    fn advanceEntities(w: *World, moved: f32) void {
        var it = w.entities.iterator();
        while (it.next()) |entry| {
            const e = entry.value;
            e.y_prev = e.y;
            e.y += moved;

            if (e.kind == .block and !e.passed and e.y >= config.player_y) {
                e.passed = true;
                const dx = @abs(w.player.x - config.laneCenter(e.lane));
                if (dx < config.near_miss_dist) {
                    w.bonus += config.near_miss_points;
                    w.events.push(.{ .near_miss = .{
                        .x = config.laneCenter(e.lane),
                        .y = e.y,
                    } });
                }
            }

            if (e.y > config.despawn_y) {
                // If a coin is still alive at the bottom of the field, the
                // player did not collect it.
                if (e.kind == .coin) {
                    w.combo = 0;
                    w.events.push(.coin_missed);
                }
                w.entities.destroy(entry.handle);
            }
        }
    }

    /// Only movement, for the crash animation. No points and no near misses.
    fn driftEntities(w: *World) void {
        const moved = w.speed() * config.tick_dt * 0.35;
        var it = w.entities.iterator();
        while (it.next()) |entry| {
            const e = entry.value;
            e.y_prev = e.y;
            e.y += moved;
            if (e.y > config.despawn_y) w.entities.destroy(entry.handle);
        }
    }

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

    fn spawnIfDue(w: *World, moved: f32) void {
        w.to_next_row -= moved;
        if (w.to_next_row > 0) return;
        w.spawnRow();
        w.to_next_row += w.rowGapUnits();
    }

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

    /// The difficulty in `[0, 1]`, from the seconds of survival.
    pub fn difficulty(w: *const World) f32 {
        return difficultyAt(w.time);
    }

    pub fn speed(w: *const World) f32 {
        return speedAt(w.time);
    }

    /// The distance before the next row.
    ///
    /// The gap is a duration, but the game puts it down as a distance. The
    /// world becomes faster while a row moves down the field. If the code
    /// spaced the rows with the *current* speed, the rows would arrive a
    /// little faster than intended. The error is largest exactly where the
    /// margin is smallest. Thus the code calculates the gap from the speed
    /// that the row will have when it arrives.
    fn rowGapUnits(w: *const World) f32 {
        const flight = (config.player_y - config.spawn_y) / w.speed();
        const arrival = w.time + flight;
        const arrival_speed = speedAt(arrival);
        return arrival_speed * rowGapSeconds(arrival_speed, arrival);
    }
};

pub fn difficultyAt(time: f32) f32 {
    return std.math.clamp(time / config.ramp_seconds, 0, 1);
}

pub fn speedAt(time: f32) f32 {
    return lerp(config.speed_start, config.speed_max, difficultyAt(time));
}

/// The seconds that a row is level with the player. During this time, the
/// player cannot cross the lane of the row. The value becomes smaller when the
/// world becomes faster.
pub fn blockedSeconds(speed: f32) f32 {
    return 2 * (config.player_half_h + config.block_half_h) / speed;
}

/// The smallest row spacing that a player can still survive at this speed. It
/// is the time to cross the full board, plus the time that the current row is
/// level with the player. Below this value, the game is impossible, however
/// open the rows look.
pub fn fairnessFloor(speed: f32) f32 {
    return 2 * config.lane_change_time + blockedSeconds(speed);
}

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

fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * std.math.clamp(t, 0, 1);
}

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

test {
    std.testing.refAllDecls(@This());
    _ = @import("pool.zig");
    _ = @import("rng.zig");
    _ = @import("bot.zig");
    _ = @import("tests.zig");
}
