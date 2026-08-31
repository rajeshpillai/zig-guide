//! A small PCG32 generator.
//!
//! The game carries its own random numbers rather than calling into std. The
//! reason is reproducibility: a seed plus a list of inputs has to replay to the
//! byte-identical run, both so the tests below can assert on exact scores and
//! so a bad run can be reported as a seed instead of a video. std's generators
//! are free to change their algorithm between releases, and this repo tracks
//! Zig master. Thirty lines here buys a sequence that cannot move underneath us.

const std = @import("std");

const Rng = @This();

state: u64,
inc: u64,

/// `stream` picks one of 2^63 distinct sequences. Two worlds with the same seed
/// and different streams do not correlate.
pub fn init(seed: u64, stream: u64) Rng {
    var self: Rng = .{ .state = 0, .inc = (stream << 1) | 1 };
    _ = self.next();
    self.state +%= seed;
    _ = self.next();
    return self;
}

pub fn next(self: *Rng) u32 {
    const old = self.state;
    self.state = old *% 6364136223846793005 +% self.inc;
    const xorshifted: u32 = @truncate(((old >> 18) ^ old) >> 27);
    const rot: u5 = @truncate(old >> 59);
    return std.math.rotr(u32, xorshifted, rot);
}

/// Uniform in `[0, bound)`, rejecting the biased tail rather than taking a
/// modulus of it. `bound` must be non-zero.
pub fn below(self: *Rng, bound: u32) u32 {
    std.debug.assert(bound != 0);
    const threshold = (@as(u32, 0) -% bound) % bound;
    while (true) {
        const r = self.next();
        if (r >= threshold) return r % bound;
    }
}

/// Uniform in `[0, 1)`, with 24 bits of mantissa.
pub fn float(self: *Rng) f32 {
    return @as(f32, @floatFromInt(self.next() >> 8)) * 0x1p-24;
}

/// True with probability `p`. Clamped, so a difficulty curve that overshoots
/// is saturating rather than undefined.
pub fn chance(self: *Rng, p: f32) bool {
    if (p <= 0) return false;
    if (p >= 1) return true;
    return self.float() < p;
}

test "same seed replays the same sequence" {
    var a: Rng = .init(12345, 0);
    var b: Rng = .init(12345, 0);
    for (0..1000) |_| try std.testing.expectEqual(a.next(), b.next());
}

test "different seeds diverge" {
    var a: Rng = .init(1, 0);
    var b: Rng = .init(2, 0);
    var same: usize = 0;
    for (0..1000) |_| {
        if (a.next() == b.next()) same += 1;
    }
    try std.testing.expect(same < 5);
}

test "below stays in range and covers it" {
    var r: Rng = .init(99, 1);
    var seen: [3]bool = @splat(false);
    for (0..10_000) |_| {
        const v = r.below(3);
        try std.testing.expect(v < 3);
        seen[v] = true;
    }
    for (seen) |s| try std.testing.expect(s);
}

test "float stays in the unit interval" {
    var r: Rng = .init(7, 2);
    for (0..10_000) |_| {
        const v = r.float();
        try std.testing.expect(v >= 0.0 and v < 1.0);
    }
}

test "chance is roughly calibrated" {
    var r: Rng = .init(31337, 3);
    var hits: usize = 0;
    const n = 100_000;
    for (0..n) |_| {
        if (r.chance(0.25)) hits += 1;
    }
    const rate = @as(f64, @floatFromInt(hits)) / n;
    try std.testing.expect(rate > 0.24 and rate < 0.26);
}
