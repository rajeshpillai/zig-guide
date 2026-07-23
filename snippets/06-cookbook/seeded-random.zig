//! title: Reproducible Randomness
//! One seed, the same world every time: the basis of replays and tests.

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
