//! Sparks, dust and score pops.
//!
//! Particles are presentation. The simulation does not know they exist: it
//! reports that a coin was collected, and this decides that means eight amber
//! dots flying outwards. That separation is what lets the feel of the game be
//! changed without any risk of changing the game, and it is why the whole
//! system reads sim events and never touches sim state.
//!
//! It reuses the same pool as the entities, which is the point of writing the
//! pool generically. There is no allocator here either.

const std = @import("std");
const sim = @import("sim");
const palette = @import("palette.zig");

const Rng = sim.Rng;
const Color = palette.Color;

pub const Particle = struct {
    x: f32,
    y: f32,
    vx: f32,
    vy: f32,
    /// Seconds remaining, counted down to zero.
    life: f32,
    life_max: f32,
    size: f32,
    /// Units per second squared, applied to vy.
    gravity: f32,
    color: Color,

    /// 1 at birth, 0 at death.
    pub fn fade(self: Particle) f32 {
        return std.math.clamp(self.life / self.life_max, 0, 1);
    }
};

pub const System = struct {
    pub const capacity = 256;
    const Pool = sim.Pool(Particle, capacity);

    pool: Pool,
    rng: Rng,

    pub fn init(seed: u64) System {
        return .{ .pool = .empty, .rng = .init(seed, 0xBEEF) };
    }

    pub fn clear(self: *System) void {
        self.pool.clear();
    }

    pub fn live(self: *const System) u16 {
        return self.pool.live;
    }

    /// Oldest-wins: when the pool is full, new particles are simply dropped.
    /// A dropped spark is invisible; stalling the frame to make room is not.
    fn emit(self: *System, p: Particle) void {
        _ = self.pool.create(p);
    }

    pub fn update(self: *System, dt: f32) void {
        var it = self.pool.iterator();
        while (it.next()) |entry| {
            const p = entry.value;
            p.life -= dt;
            if (p.life <= 0) {
                self.pool.destroy(entry.handle);
                continue;
            }
            p.vy += p.gravity * dt;
            p.x += p.vx * dt;
            p.y += p.vy * dt;
        }
    }

    pub fn iterator(self: *System) Pool.Iterator {
        return self.pool.iterator();
    }

    /// A ring of sparks, used for coins.
    pub fn burst(self: *System, x: f32, y: f32, count: usize, color: Color, speed: f32) void {
        for (0..count) |i| {
            const turn = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(count));
            const angle = turn * std.math.tau + self.rng.float() * 0.4;
            const magnitude = speed * (0.6 + self.rng.float() * 0.8);
            const life = 0.35 + self.rng.float() * 0.3;
            self.emit(.{
                .x = x,
                .y = y,
                .vx = @cos(angle) * magnitude,
                .vy = @sin(angle) * magnitude,
                .life = life,
                .life_max = life,
                .size = 3 + self.rng.float() * 3,
                .gravity = 420,
                .color = color,
            });
        }
    }

    /// A wider, slower, heavier burst for the crash.
    pub fn debris(self: *System, x: f32, y: f32) void {
        for (0..28) |_| {
            const angle = (self.rng.float() - 0.5) * std.math.pi * 1.6 - std.math.pi / 2.0;
            const magnitude = 120 + self.rng.float() * 340;
            const life = 0.5 + self.rng.float() * 0.6;
            self.emit(.{
                .x = x,
                .y = y,
                .vx = @cos(angle) * magnitude,
                .vy = @sin(angle) * magnitude,
                .life = life,
                .life_max = life,
                .size = 3 + self.rng.float() * 5,
                .gravity = 900,
                .color = if (self.rng.chance(0.5)) palette.block else palette.block_top,
            });
        }
    }

    /// A short horizontal smear behind the player when they commit to a lane.
    pub fn dust(self: *System, x: f32, y: f32, direction: f32) void {
        for (0..6) |_| {
            const life = 0.18 + self.rng.float() * 0.16;
            self.emit(.{
                .x = x,
                .y = y + (self.rng.float() - 0.5) * 30,
                .vx = -direction * (60 + self.rng.float() * 120),
                .vy = (self.rng.float() - 0.5) * 40,
                .life = life,
                .life_max = life,
                .size = 2 + self.rng.float() * 3,
                .gravity = 0,
                .color = palette.player_dark,
            });
        }
    }

    /// Two vertical streaks marking a block that went by close.
    pub fn graze(self: *System, x: f32, y: f32) void {
        for (0..8) |_| {
            const life = 0.25 + self.rng.float() * 0.2;
            self.emit(.{
                .x = x + (self.rng.float() - 0.5) * 40,
                .y = y + (self.rng.float() - 0.5) * 50,
                .vx = (self.rng.float() - 0.5) * 60,
                .vy = 260 + self.rng.float() * 200,
                .life = life,
                .life_max = life,
                .size = 2 + self.rng.float() * 2,
                .gravity = 0,
                .color = palette.good,
            });
        }
    }
};

test "particles expire and free their slots" {
    var system: System = .init(1);
    system.burst(100, 100, 12, palette.coin, 200);
    try std.testing.expect(system.live() > 0);

    var elapsed: f32 = 0;
    while (elapsed < 3) : (elapsed += 1.0 / 60.0) system.update(1.0 / 60.0);
    try std.testing.expectEqual(@as(u16, 0), system.live());
}

test "a full pool drops particles instead of misbehaving" {
    var system: System = .init(2);
    for (0..200) |_| system.burst(10, 10, 16, palette.coin, 100);
    try std.testing.expect(system.live() <= System.capacity);

    // And it still runs and drains cleanly afterwards.
    var elapsed: f32 = 0;
    while (elapsed < 3) : (elapsed += 1.0 / 60.0) system.update(1.0 / 60.0);
    try std.testing.expectEqual(@as(u16, 0), system.live());
}

test "fade runs from one to zero" {
    var system: System = .init(3);
    system.burst(0, 0, 4, palette.coin, 50);
    var it = system.iterator();
    while (it.next()) |entry| {
        try std.testing.expectApproxEqAbs(@as(f32, 1), entry.value.fade(), 0.0001);
    }
    for (0..1000) |_| system.update(1.0 / 240.0);
    it = system.iterator();
    while (it.next()) |entry| {
        try std.testing.expect(entry.value.fade() >= 0 and entry.value.fade() <= 1);
    }
}

test "gravity pulls particles down" {
    var system: System = .init(4);
    system.burst(0, 0, 8, palette.coin, 10);
    for (0..30) |_| system.update(1.0 / 60.0);
    var falling: usize = 0;
    var it = system.iterator();
    while (it.next()) |entry| {
        if (entry.value.vy > 0) falling += 1;
    }
    try std.testing.expect(falling > 0);
}
