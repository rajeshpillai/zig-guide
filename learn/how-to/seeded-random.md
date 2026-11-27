# Recipe: Reproducible Randomness

> Seeded generators make random worlds, tests and replays repeatable.

For repeatable randomness in Zig, make a generator from a fixed seed with `std.Random.DefaultPrng.init(42)`. Give `prng.random()` to the code that needs it. On the same Zig version, the same seed gives the same output on all platforms.

## The problem

Your program makes something random: a game map, test data or a shuffled playlist. Then a bug report comes. You need the exact map that the user saw, not a new random map. Or a test fails one time in fifty runs, and you need that run again.

In each of these cases, the randomness must come from a seed that you control. Zig has no hidden global generator. Thus the code always gives the generator explicitly.

## The plan

1. Make a deterministic generator from a seed.
2. Give its `std.Random` interface to the code that needs randomness. That code cannot see a difference between a seeded generator and a generator with a new seed.
3. Store or log the seed. When you use the seed again, you get again all of the data that came from the seed.

```zig
const std = @import("std");

const Side = 8;

// All of the values come from the Random interface in the argument. Thus
// the caller controls the seed, and with it the determinism.
fn generateCave(random: std.Random, grid: *[Side][Side]u8) void {
    for (grid) |*row| {
        for (row) |*cell| {
            // 40% wall, 60% floor.
            cell.* = if (random.uintLessThan(u8, 10) < 4) '#' else '.';
        }
    }
}

pub fn main(init: std.process.Init) !void {
    var buf: [2048]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    // Save only the seed. Put the seed in a bug report, and the program
    // builds exactly the same cave again.
    var prng = std.Random.DefaultPrng.init(42);
    var cave: [Side][Side]u8 = undefined;
    generateCave(prng.random(), &cave);

    try out.print("seed 42:\n", .{});
    for (cave) |row| try out.print("  {s}\n", .{&row});

    // The same seed and a new generator give a world with identical bytes.
    var replay = std.Random.DefaultPrng.init(42);
    var again: [Side][Side]u8 = undefined;
    generateCave(replay.random(), &again);
    try out.print("same seed reproduces: {}\n", .{
        std.mem.eql(u8, std.mem.asBytes(&cave), std.mem.asBytes(&again)),
    });

    // A different seed gives a different world.
    var other = std.Random.DefaultPrng.init(43);
    var different: [Side][Side]u8 = undefined;
    generateCave(other.random(), &different);
    try out.print("different seed differs: {}\n", .{
        !std.mem.eql(u8, std.mem.asBytes(&cave), std.mem.asBytes(&different)),
    });

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`06-cookbook.seeded-random`)*

## Give the `std.Random` interface

`generateCave` takes `std.Random`, not a concrete generator. In production, you can make the seed from the clock or from entropy. In a test or a replay, you give a fixed seed.

The code that makes the cave is the same in both cases. The call site decides if the output is reproducible, and the algorithm does not change.

You can also nest seeds. A world seed can make a seed for each system (terrain, loot, weather). The program draws these seeds from the master generator. Then you can replay each subsystem by itself.

## What a seed promises

With the same seed and the same Zig version, the output is identical on all platforms, wasm too. This page is the proof: CI compares the cave above, byte for byte, with an expected output that is in the repository.

On a different Zig version, the sequence can change if the default PRNG algorithm changes. If saved seeds must work after compiler upgrades, give the name of an algorithm explicitly (for example `std.Random.Xoshiro256`). Do not use `DefaultPrng`.

## Do not use a PRNG for secrets

A seeded PRNG is predictable on purpose. Keys, tokens and all other data that an attacker must not guess need entropy from the operating system.

On master, that entropy comes through `std.Random.IoSource`, which fills bytes from the `Io` interface. You can also use a `std.Random.DefaultCsprng` that gets its seed from `IoSource`.

There is no global secure generator now. Zig removed `std.crypto.random`. Thus the code gives the capability as an argument, as it does for each other effect.

The rule:

- If a replay of the values can be useful, use a PRNG.
- If a replay of the values is a vulnerability, use the secure generator.

See [Random Numbers](https://www.ziglang.in/learn/standard-library/random-numbers/) for more information about both generators.
