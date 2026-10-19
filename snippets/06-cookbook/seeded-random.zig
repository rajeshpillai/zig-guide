//! title: Reproducible Randomness
//! One seed gives the same world each time. Replays and tests use this.

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
