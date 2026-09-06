# Recipe: Reproducible Randomness

> Seeded generators make random worlds, tests, and replays repeatable.

## The problem

Your program generates something random: a game map, test data, a shuffled
playlist. A bug report arrives. You need the exact map the user saw, not a
fresh roll of the dice. Or a test fails once in fifty runs and you need
that run back.

The answer is the same in every case: randomness must flow from a seed you
control, through a generator you pass around explicitly. Zig's design makes
the explicit part unavoidable, which is why this works so well here: there
is no hidden global generator to reach for.

## The plan

1. Create a deterministic generator from a seed:
   `std.Random.DefaultPrng.init(42)`.
2. Hand `prng.random()` (the `std.Random` interface) to the code that needs
   randomness. That code cannot tell a seeded generator from a fresh one,
   which is the point.
3. Store or log the seed. The seed is the save file: replaying it recreates
   everything derived from it.

```zig
const std = @import("std");

const Side = 8;

// Everything derives from the Random interface handed in, so the caller
// controls determinism by controlling the seed.
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

    // The seed is the save file. Ship it in a bug report and the exact
    // same cave comes back.
    var prng = std.Random.DefaultPrng.init(42);
    var cave: [Side][Side]u8 = undefined;
    generateCave(prng.random(), &cave);

    try out.print("seed 42:\n", .{});
    for (cave) |row| try out.print("  {s}\n", .{&row});

    // Same seed, fresh generator: byte-identical world.
    var replay = std.Random.DefaultPrng.init(42);
    var again: [Side][Side]u8 = undefined;
    generateCave(replay.random(), &again);
    try out.print("same seed reproduces: {}\n", .{
        std.mem.eql(u8, std.mem.asBytes(&cave), std.mem.asBytes(&again)),
    });

    // A different seed diverges.
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

## The interface is the trick

`generateCave` takes `std.Random`, not a concrete generator. In production
you might seed from the clock or entropy; in a test or a replay you pass a
fixed seed. The generating code is identical in both worlds, so
reproducibility is a property of the call site, not something the algorithm
has to opt into.

This composes: a world seed can derive per-system seeds (terrain, loot,
weather) by drawing them from the master generator, and each subsystem
stays independently replayable.

## What a seed does and does not promise

Same seed, same Zig version: identical output, on every platform, wasm
included. The page you are reading proves it, since CI verifies the cave
above byte-for-byte against a checked-in expectation.

Across Zig versions the sequence may change if the default PRNG algorithm
changes. If saved seeds must outlive compiler upgrades, name an algorithm
explicitly (for example `std.Random.Xoshiro256`) instead of `DefaultPrng`.

## Not for secrets

Seeded PRNGs are predictable by design; that is their feature. Keys,
tokens, and anything an attacker must not guess come from
`std.crypto.random` instead, which cannot be seeded. The dividing line:
if you would ever want to replay it, use a PRNG; if replaying it would be
a vulnerability, use crypto randomness. See
[Random Numbers](https://www.ziglang.in/learn/standard-library/random-numbers/) for the tour of both.
