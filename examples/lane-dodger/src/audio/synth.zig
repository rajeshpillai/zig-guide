//! Sound effects that the game generates, and does not load.
//!
//! This repository has no `.wav` files, and it will not have them. Five short
//! sounds are a few hundred lines of arithmetic. As code, you can diff the
//! sounds, and you can adjust a sound when you change a number. Also, the code
//! has no licence question, and each sample pack has one. The full game stays
//! a tree of text files. For the same reason, the graphics are shapes and not
//! sprites.
//!
//! Like the particle system, this file contains no raylib types. It fills a
//! buffer with 16-bit samples and stops. `platform/audio.zig` gives that buffer
//! to an audio device. The tests below check the waveforms without an audio
//! device.

const std = @import("std");
const sim = @import("sim");

const Rng = sim.Rng;

/// Sufficient for short sounds whose highest frequencies are a few kilohertz.
/// It uses half the memory of 44.1k.
pub const sample_rate: u32 = 22_050;

/// The longest clip is the crash. It lasts for most of a second, because the
/// descending triad is part of the crash and not a second sound.
pub const max_samples: usize = 24_576;

pub const Shape = enum { sine, triangle, square, noise };

/// One oscillator with an envelope. A sound is a stack of a few layers.
pub const Layer = struct {
    shape: Shape,
    /// The frequency at the start and at the end of the layer. The sweep is
    /// exponential. Thus the slide is even in pitch, and not in hertz. `noise`
    /// ignores these values.
    from: f32,
    to: f32,
    /// Seconds. `delay` starts a layer later than the others. The arpeggios
    /// use `delay`.
    duration: f32,
    delay: f32 = 0,
    gain: f32 = 0.5,
    /// The seconds of fade in. Never zero. A waveform that starts at full
    /// amplitude starts with a step, and a step is a click.
    attack: f32 = 0.004,
    /// The shape of the decay. 1 is a straight line to silence. A higher value
    /// gives a faster drop at the start and a longer tail.
    curve: f32 = 2.5,
    /// A one-pole low pass. 1 means no filter. It removes the high hiss from
    /// the noise burst.
    lowpass: f32 = 1,
};

/// Render `layers` into `out`. Returns the number of samples that it wrote.
///
/// The envelope is exactly zero at the two ends of each layer. This prevents
/// clicks. If a clip starts or stops at a point above zero on a waveform, the
/// clip makes a discontinuity. A discontinuity is a click, and the click is
/// much louder and more unpleasant than its sound.
pub fn render(layers: []const Layer, out: []i16, seed: u64) usize {
    var total: f32 = 0;
    for (layers) |layer| total = @max(total, layer.delay + layer.duration);

    const count = @min(out.len, @as(usize, @intFromFloat(total * @as(f32, sample_rate))));
    if (count == 0) return 0;

    var mixed: [max_samples]f32 = @splat(0);
    const window = mixed[0..@min(count, mixed.len)];

    var rng: Rng = .init(seed, 0x5040);
    for (layers) |layer| {
        var filtered: f32 = 0;
        var phase: f32 = 0;
        const offset: usize = @intFromFloat(layer.delay * @as(f32, sample_rate));
        const length: usize = @intFromFloat(layer.duration * @as(f32, sample_rate));
        if (length == 0) continue;

        for (0..length) |i| {
            const index = offset + i;
            if (index >= window.len) break;

            const t = @as(f32, @floatFromInt(i)) / @as(f32, sample_rate);
            const progress = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(length));

            // An exponential sweep is even in pitch, and not in hertz.
            const frequency = layer.from * std.math.pow(f32, layer.to / layer.from, progress);
            phase += std.math.tau * frequency / @as(f32, sample_rate);
            if (phase > std.math.tau) phase -= std.math.tau;

            var value: f32 = switch (layer.shape) {
                .sine => @sin(phase),
                .triangle => 1 - 4 * @abs(@round(phase / std.math.tau) - phase / std.math.tau),
                .square => if (phase < std.math.pi) 1 else -1,
                .noise => rng.float() * 2 - 1,
            };
            if (layer.lowpass < 1) {
                filtered += layer.lowpass * (value - filtered);
                value = filtered;
            }

            mixed[index] += value * layer.gain * envelope(t, layer);
        }
    }

    // A soft clip, and not a hard clip. Layers on top of each other go past
    // the limit. tanh bends the peaks, and does not cut them flat.
    for (window, 0..) |value, i| {
        const shaped = std.math.tanh(value);
        out[i] = @intFromFloat(std.math.clamp(shaped, -1, 1) * 32_600);
    }
    return window.len;
}

fn envelope(t: f32, layer: Layer) f32 {
    if (t < layer.attack) return t / layer.attack;
    const remaining = layer.duration - layer.attack;
    if (remaining <= 0) return 0;
    const decayed = 1 - (t - layer.attack) / remaining;
    if (decayed <= 0) return 0;
    return std.math.pow(f32, decayed, layer.curve);
}

/// The five sounds of the game. The pitch for the combo steps changes at
/// playback, and is not part of the samples. Thus the game has one coin sound
/// and not eight.
pub const coin: []const Layer = &.{
    .{ .shape = .triangle, .from = 900, .to = 1350, .duration = 0.085, .gain = 0.55 },
    .{ .shape = .sine, .from = 1800, .to = 2700, .duration = 0.07, .gain = 0.22 },
};

pub const near_miss: []const Layer = &.{
    .{ .shape = .noise, .from = 1, .to = 1, .duration = 0.13, .gain = 0.3, .lowpass = 0.35, .curve = 3 },
    .{ .shape = .sine, .from = 1500, .to = 520, .duration = 0.13, .gain = 0.16, .curve = 3 },
};

pub const lane: []const Layer = &.{
    .{ .shape = .noise, .from = 1, .to = 1, .duration = 0.05, .gain = 0.2, .lowpass = 0.5, .curve = 3.5 },
    .{ .shape = .sine, .from = 420, .to = 300, .duration = 0.05, .gain = 0.14, .curve = 3 },
};

/// An impact, then a descending triad.
///
/// One event, one sound. The alternative was two sounds. The thud would play
/// at the crash, and the sting would play when the retry prompt appears. Then
/// the game must record if it played the sting yet, for a run that is already
/// lost. A layer can have a delay. Thus the pause is in the waveform.
pub const crash: []const Layer = &.{
    .{ .shape = .noise, .from = 1, .to = 1, .duration = 0.45, .gain = 0.5, .lowpass = 0.12, .curve = 2 },
    .{ .shape = .square, .from = 220, .to = 55, .duration = 0.4, .gain = 0.28, .curve = 1.6 },
    .{ .shape = .sine, .from = 130, .to = 40, .duration = 0.5, .gain = 0.35, .curve = 1.4 },
    .{ .shape = .triangle, .from = 587, .to = 587, .duration = 0.12, .delay = 0.38, .gain = 0.3 },
    .{ .shape = .triangle, .from = 466, .to = 466, .duration = 0.12, .delay = 0.49, .gain = 0.3 },
    .{ .shape = .triangle, .from = 349, .to = 349, .duration = 0.3, .delay = 0.6, .gain = 0.34, .curve = 1.8 },
};

/// An ascending third. The game plays it when a run starts.
pub const start: []const Layer = &.{
    .{ .shape = .triangle, .from = 523, .to = 523, .duration = 0.09, .gain = 0.4 },
    .{ .shape = .triangle, .from = 659, .to = 659, .duration = 0.09, .delay = 0.075, .gain = 0.4 },
    .{ .shape = .triangle, .from = 784, .to = 784, .duration = 0.16, .delay = 0.15, .gain = 0.45 },
};

pub const all: []const []const Layer = &.{ coin, near_miss, lane, crash, start };

const testing = std.testing;

fn peak(samples: []const i16) i32 {
    var highest: i32 = 0;
    for (samples) |s| highest = @max(highest, @as(i32, @intCast(@abs(@as(i32, s)))));
    return highest;
}

test "every sound fits its buffer and makes a sound" {
    var buffer: [max_samples]i16 = undefined;
    for (all) |layers| {
        const written = render(layers, &buffer, 1);
        try testing.expect(written > 0);
        try testing.expect(written <= max_samples);
        // Sufficiently loud to hear.
        try testing.expect(peak(buffer[0..written]) > 8_000);
    }
}

test "no sound begins or ends with a click" {
    // If a clip starts or stops at a point above zero on a waveform, the clip
    // has a step change. A step change is a click, and the click is louder and
    // more unpleasant than its effect. The envelope prevents the click, at the
    // two ends.
    var buffer: [max_samples]i16 = undefined;
    for (all, 0..) |layers, index| {
        const written = render(layers, &buffer, 2);
        testing.expect(@abs(@as(i32, buffer[0])) < 400) catch |err| {
            std.debug.print("sound {d} starts at {d}\n", .{ index, buffer[0] });
            return err;
        };
        testing.expect(@abs(@as(i32, buffer[written - 1])) < 400) catch |err| {
            std.debug.print("sound {d} ends at {d}\n", .{ index, buffer[written - 1] });
            return err;
        };
    }
}

test "nothing clips flat against the rail" {
    // A soft clip bends the peaks. A hard clip cuts them flat. A flat peak is
    // a series of identical maximum samples.
    var buffer: [max_samples]i16 = undefined;
    for (all, 0..) |layers, index| {
        const written = render(layers, &buffer, 3);
        var run: usize = 0;
        var longest: usize = 0;
        for (buffer[0..written]) |s| {
            if (@abs(@as(i32, s)) >= 32_600) run += 1 else run = 0;
            longest = @max(longest, run);
        }
        testing.expect(longest < 8) catch |err| {
            std.debug.print("sound {d} sits at the rail for {d} samples\n", .{ index, longest });
            return err;
        };
    }
}

/// Zero crossings each second. This is an approximate estimate of pitch. It is
/// sufficient to tell a high chime from a low thud.
fn brightness(samples: []const i16, rate: u32) f32 {
    var crossings: usize = 0;
    for (samples[1..], 0..) |s, i| {
        if ((samples[i] < 0) != (s < 0)) crossings += 1;
    }
    const seconds = @as(f32, @floatFromInt(samples.len)) / @as(f32, @floatFromInt(rate));
    return @as(f32, @floatFromInt(crossings)) / 2 / seconds;
}

test "the sounds sit in the right places against each other" {
    // The exact frequencies are a design decision, and they can change. The
    // order must not change. The crash is the low, long and loud sound. The
    // lane tick is the short and quiet sound. If that order changed, you would
    // hear it in one second, but a diff would not show it.
    var buffer: [max_samples]i16 = undefined;

    const written_coin = render(coin, &buffer, 7);
    const coin_hz = brightness(buffer[0..written_coin], sample_rate);
    const coin_peak = peak(buffer[0..written_coin]);

    const written_crash = render(crash, &buffer, 7);
    const crash_hz = brightness(buffer[0..written_crash], sample_rate);
    const crash_peak = peak(buffer[0..written_crash]);

    const written_lane = render(lane, &buffer, 7);
    const lane_peak = peak(buffer[0..written_lane]);

    // The coin is a chime and the crash is a thud.
    try testing.expect(coin_hz > crash_hz * 2);
    // The coin is in the band of its sweep.
    try testing.expect(coin_hz > 800 and coin_hz < 1600);

    // The crash is the longest sound of the game, and the loudest.
    try testing.expect(written_crash > written_coin * 4);
    try testing.expect(crash_peak >= coin_peak);

    // The lane tick is the shortest sound, and it must be quieter than a
    // pickup. It plays on each input. If an input sound is as loud as a reward
    // sound, players turn off the sound of the game.
    try testing.expect(written_lane < written_coin);
    try testing.expect(lane_peak < coin_peak);
}

test "rendering is deterministic" {
    var a: [max_samples]i16 = undefined;
    var b: [max_samples]i16 = undefined;
    const first = render(crash, &a, 99);
    const second = render(crash, &b, 99);
    try testing.expectEqual(first, second);
    try testing.expectEqualSlices(i16, a[0..first], b[0..second]);
}

test "the envelope falls to silence and never exceeds full scale" {
    const layer: Layer = .{ .shape = .sine, .from = 440, .to = 440, .duration = 0.2 };
    try testing.expectApproxEqAbs(@as(f32, 0), envelope(0, layer), 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0), envelope(layer.duration, layer), 0.0001);

    var t: f32 = 0;
    while (t <= layer.duration) : (t += 0.001) {
        const value = envelope(t, layer);
        try testing.expect(value >= 0 and value <= 1.0001);
    }
}

test "the tail decays monotonically" {
    const layer: Layer = .{ .shape = .sine, .from = 440, .to = 440, .duration = 0.2 };
    var previous = envelope(layer.attack, layer);
    var t: f32 = layer.attack;
    while (t <= layer.duration) : (t += 0.001) {
        const value = envelope(t, layer);
        try testing.expect(value <= previous + 0.0001);
        previous = value;
    }
}

test "a delayed layer starts silent" {
    var buffer: [max_samples]i16 = undefined;
    const written = render(&.{
        .{ .shape = .sine, .from = 800, .to = 800, .duration = 0.05, .delay = 0.1 },
    }, &buffer, 4);
    try testing.expect(written > 0);
    // No sound before the end of the delay.
    const silent_until = @as(usize, @intFromFloat(0.09 * @as(f32, sample_rate)));
    for (buffer[0..silent_until]) |s| try testing.expectEqual(@as(i16, 0), s);
}

test "a zero length layer is ignored rather than dividing by zero" {
    var buffer: [max_samples]i16 = undefined;
    _ = render(&.{
        .{ .shape = .sine, .from = 440, .to = 440, .duration = 0 },
    }, &buffer, 5);
}
