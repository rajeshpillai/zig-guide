//! Sound effects, generated rather than loaded.
//!
//! There are no `.wav` files in this repository and there is not going to be.
//! Six short blips are a few hundred lines of arithmetic, and writing them out
//! means the sounds are diffable, tunable by changing a number, and free of the
//! licensing question that comes with every sample pack. It also keeps the
//! whole game a text tree, which is the same reason the graphics are shapes and
//! not sprites.
//!
//! Like the particle system, this holds no raylib types. It fills a buffer with
//! 16-bit samples and stops. `platform/audio.zig` is what hands that buffer to
//! an audio device, and the tests below check the waveforms without one.

const std = @import("std");
const sim = @import("sim");

const Rng = sim.Rng;

/// Plenty for blips whose brightest content is a few kilohertz, and half the
/// memory of 44.1k.
pub const sample_rate: u32 = 22_050;

/// The longest clip is the crash, which runs on for most of a second because
/// the falling triad is part of it rather than a second cue.
pub const max_samples: usize = 24_576;

pub const Shape = enum { sine, triangle, square, noise };

/// One oscillator with an envelope. Sounds are built by stacking a few.
pub const Layer = struct {
    shape: Shape,
    /// Frequency at the start and end of the layer, swept exponentially so the
    /// slide is even in pitch rather than in hertz. Ignored by `noise`.
    from: f32,
    to: f32,
    /// Seconds. `delay` staggers layers, which is how the arpeggios are made.
    duration: f32,
    delay: f32 = 0,
    gain: f32 = 0.5,
    /// Seconds of fade in. Never zero: a waveform that begins at full
    /// amplitude begins with a step, and a step is a click.
    attack: f32 = 0.004,
    /// Decay shape. 1 is a straight line to silence, higher is a sharper
    /// initial drop and a longer tail.
    curve: f32 = 2.5,
    /// One-pole low pass, 1 for none. Takes the fizz off the noise burst.
    lowpass: f32 = 1,
};

/// Render `layers` into `out`, returning the number of samples written.
///
/// The envelope reaches exactly zero at both ends of every layer. That is not
/// tidiness: a clip that starts or stops partway up a waveform produces a
/// discontinuity, and a discontinuity is a click that is far louder and more
/// annoying than the sound it is attached to.
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

            // Exponential sweep: even in pitch rather than in hertz.
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

    // Soft clip rather than hard: stacked layers overshoot, and tanh bends the
    // peaks instead of shearing them flat.
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

/// The six sounds the game makes. Pitch for the combo ladder is applied at
/// playback rather than baked in, so there is one coin sound and not eight.
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

/// Impact, then a falling triad.
///
/// One event, one sound. The alternative was to play the thud on the crash and
/// the sting when the retry prompt appears, which means the game has to
/// remember whether it has played the sting yet, for a run it has already lost.
/// Layers take a delay, so the pause is in the waveform instead.
pub const crash: []const Layer = &.{
    .{ .shape = .noise, .from = 1, .to = 1, .duration = 0.45, .gain = 0.5, .lowpass = 0.12, .curve = 2 },
    .{ .shape = .square, .from = 220, .to = 55, .duration = 0.4, .gain = 0.28, .curve = 1.6 },
    .{ .shape = .sine, .from = 130, .to = 40, .duration = 0.5, .gain = 0.35, .curve = 1.4 },
    .{ .shape = .triangle, .from = 587, .to = 587, .duration = 0.12, .delay = 0.38, .gain = 0.3 },
    .{ .shape = .triangle, .from = 466, .to = 466, .duration = 0.12, .delay = 0.49, .gain = 0.3 },
    .{ .shape = .triangle, .from = 349, .to = 349, .duration = 0.3, .delay = 0.6, .gain = 0.34, .curve = 1.8 },
};

/// A rising third, played when a run begins.
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
        // Audible, not a whisper.
        try testing.expect(peak(buffer[0..written]) > 8_000);
    }
}

test "no sound begins or ends with a click" {
    // A clip that starts or stops partway up a waveform is a step change, and a
    // step change is a click that is louder and more irritating than the effect
    // it is attached to. The envelope is what prevents it, at both ends.
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
    // Soft clipping bends the peaks; hard clipping shears them, and a run of
    // identical maximum samples is what that sounds like.
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

/// Zero crossings per second: a crude pitch estimate, and a good enough
/// brightness measure to tell a chime from a thud.
fn brightness(samples: []const i16, rate: u32) f32 {
    var crossings: usize = 0;
    for (samples[1..], 0..) |s, i| {
        if ((samples[i] < 0) != (s < 0)) crossings += 1;
    }
    const seconds = @as(f32, @floatFromInt(samples.len)) / @as(f32, @floatFromInt(rate));
    return @as(f32, @floatFromInt(crossings)) / 2 / seconds;
}

test "the sounds sit in the right places against each other" {
    // Absolute frequencies are a matter of taste and are allowed to move. What
    // must not move is the arrangement: the crash is the low, long, loud one
    // and the lane tick is the short quiet one. Getting that backwards is the
    // kind of mistake that is obvious in a second of listening and invisible in
    // a diff.
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
    // The coin sits in the band it is swept across.
    try testing.expect(coin_hz > 800 and coin_hz < 1600);

    // The crash is the longest thing the game plays, and the loudest.
    try testing.expect(written_crash > written_coin * 4);
    try testing.expect(crash_peak >= coin_peak);

    // The lane tick is the shortest, and must not shout over a pickup: it
    // fires on every input, and an input sound as loud as a reward sound is
    // how a game ends up muted.
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
    // Nothing at all before the delay elapses.
    const silent_until = @as(usize, @intFromFloat(0.09 * @as(f32, sample_rate)));
    for (buffer[0..silent_until]) |s| try testing.expectEqual(@as(i16, 0), s);
}

test "a zero length layer is ignored rather than dividing by zero" {
    var buffer: [max_samples]i16 = undefined;
    _ = render(&.{
        .{ .shape = .sine, .from = 440, .to = 440, .duration = 0 },
    }, &buffer, 5);
}
