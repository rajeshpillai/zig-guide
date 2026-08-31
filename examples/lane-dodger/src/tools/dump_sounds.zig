//! Write the game's sound effects out as `.wav` files, for listening to
//! without launching the game.
//!
//! Tuning a sound by rebuilding a game, starting a run and crashing into a
//! block on purpose is a slow loop. `zig build sounds` writes them to
//! `zig-out/sounds/` instead, where any player will open them.

const std = @import("std");
const synth = @import("synth");

const Clip = struct { name: []const u8, layers: []const synth.Layer };

const clips: []const Clip = &.{
    .{ .name = "coin", .layers = synth.coin },
    .{ .name = "near-miss", .layers = synth.near_miss },
    .{ .name = "lane", .layers = synth.lane },
    .{ .name = "crash", .layers = synth.crash },
    .{ .name = "start", .layers = synth.start },
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var out_buffer: [256]u8 = undefined;
    var stdout = std.Io.File.stdout().writerStreaming(io, &out_buffer);
    const out = &stdout.interface;

    // The build passes the output directory, so the step is cache-correct:
    // the files are an output of the run rather than something it scribbles
    // into the source tree.
    var args = init.minimal.args.iterate();
    _ = args.next();
    const target_dir = args.next() orelse return error.MissingOutputDirectory;

    var dir = try std.Io.Dir.cwd().openDir(io, target_dir, .{});
    defer dir.close(io);
    var samples: [synth.max_samples]i16 = undefined;

    for (clips) |clip| {
        const count = synth.render(clip.layers, &samples, 1);

        var name_buffer: [64]u8 = undefined;
        const name = try std.mem.print(&name_buffer, "{s}.wav", .{clip.name});

        const file = try dir.createFile(io, name, .{});
        defer file.close(io);

        try file.writeStreamingAll(io, &header(count));
        try file.writeStreamingAll(io, std.mem.sliceAsBytes(samples[0..count]));

        try out.print("{s}  {d} samples  {d:.3}s\n", .{
            name,
            count,
            @as(f32, @floatFromInt(count)) / @as(f32, synth.sample_rate),
        });
    }
    try out.flush();
}

/// A 44-byte canonical WAV header for 16-bit mono PCM.
fn header(frames: usize) [44]u8 {
    const data_bytes: u32 = @intCast(frames * 2);
    const byte_rate: u32 = synth.sample_rate * 2;

    var bytes: [44]u8 = undefined;
    @memcpy(bytes[0..4], "RIFF");
    std.mem.writeInt(u32, bytes[4..8], 36 + data_bytes, .little);
    @memcpy(bytes[8..12], "WAVE");
    @memcpy(bytes[12..16], "fmt ");
    std.mem.writeInt(u32, bytes[16..20], 16, .little); // PCM chunk size
    std.mem.writeInt(u16, bytes[20..22], 1, .little); // uncompressed
    std.mem.writeInt(u16, bytes[22..24], 1, .little); // mono
    std.mem.writeInt(u32, bytes[24..28], synth.sample_rate, .little);
    std.mem.writeInt(u32, bytes[28..32], byte_rate, .little);
    std.mem.writeInt(u16, bytes[32..34], 2, .little); // block align
    std.mem.writeInt(u16, bytes[34..36], 16, .little); // bits per sample
    @memcpy(bytes[36..40], "data");
    std.mem.writeInt(u32, bytes[40..44], data_bytes, .little);
    return bytes;
}
