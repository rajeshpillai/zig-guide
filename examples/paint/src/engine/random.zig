//! Repeatable randomness.
//!
//! A brush that varies its marks must vary them the same way every time the
//! same stroke is replayed, or a replay test could never compare two pictures.
//! So the engine never asks the machine for randomness. It carries its own
//! generator, started from a seed.
//!
//! This is Park and Miller's "minimal standard" generator: multiply by 16807
//! and keep the remainder after dividing by 2^31 - 1. It is small enough to
//! check by hand, and its sequence is the same on every machine.

const std = @import("std");

pub const Random = struct {
    /// Always between 1 and 2^31 - 2. Zero would stay zero for ever.
    state: u32,

    const modulus: u64 = 2147483647; // 2^31 - 1, a prime
    const multiplier: u64 = 16807; // 7^5

    pub fn init(seed: u32) Random {
        const s: u32 = @intCast(seed % modulus);
        return .{ .state = if (s == 0) 1 else s };
    }

    /// The next value, from 0.0 to 1.0.
    pub fn next(r: *Random) f32 {
        // The product needs 46 bits, so it is done in u64. In u32 it would
        // overflow, and Zig would stop the program in a safe build.
        r.state = @intCast(@as(u64, r.state) * multiplier % modulus);
        return @as(f32, @floatFromInt(r.state - 1)) / 2147483646.0;
    }
};

test "the first values from seed 1 are the published ones" {
    // Park and Miller give 16807, 282475249 and 1622650073 as the first three
    // states from seed 1, so a wrong multiplication shows up here.
    var r = Random.init(1);
    _ = r.next();
    try std.testing.expectEqual(@as(u32, 16807), r.state);
    _ = r.next();
    try std.testing.expectEqual(@as(u32, 282475249), r.state);
    _ = r.next();
    try std.testing.expectEqual(@as(u32, 1622650073), r.state);
}

test "the same seed repeats, a different seed does not" {
    var a = Random.init(42);
    var b = Random.init(42);
    var c = Random.init(43);
    var differs = false;
    for (0..100) |_| {
        const va = a.next();
        try std.testing.expectEqual(va, b.next());
        if (va != c.next()) differs = true;
        try std.testing.expect(va >= 0.0 and va <= 1.0);
    }
    try std.testing.expect(differs);
}

test "seed zero is moved off zero" {
    var r = Random.init(0);
    _ = r.next();
    try std.testing.expect(r.state != 0);
}
