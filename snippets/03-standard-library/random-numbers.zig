//! title: Random Numbers
//! Seeded PRNGs you pass around explicitly.

const std = @import("std");
const expect = std.testing.expect;

test "a seeded generator is reproducible" {
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();

    const first = random.int(u32);

    // Same seed, same sequence — which is what makes tests deterministic.
    var again = std.Random.DefaultPrng.init(42);
    try expect(again.random().int(u32) == first);
}

test "ranges" {
    var prng = std.Random.DefaultPrng.init(0);
    const random = prng.random();

    for (0..100) |_| {
        const die = random.intRangeAtMost(u8, 1, 6); // inclusive
        try expect(die >= 1 and die <= 6);

        const index = random.uintLessThan(usize, 10); // exclusive
        try expect(index < 10);
    }
}

test "floats and booleans" {
    var prng = std.Random.DefaultPrng.init(7);
    const random = prng.random();

    const f = random.float(f64); // [0, 1)
    try expect(f >= 0.0 and f < 1.0);

    _ = random.boolean();
}

test "shuffle a slice" {
    var prng = std.Random.DefaultPrng.init(1);
    var items = [_]u8{ 1, 2, 3, 4, 5 };
    prng.random().shuffle(u8, &items);

    var sum: u32 = 0;
    for (items) |i| sum += i;
    try expect(sum == 15); // same elements, different order
}
