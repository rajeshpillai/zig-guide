# Sound Without Sound Files

> Five effects that the game synthesises at startup from oscillators and envelopes, and waveform tests that run without an audio device.

This project has no audio files. The five effects are arithmetic. The game
generates them when it starts.

To record or license five short sounds would take less time than to write a
synthesiser. But that choice also adds three costs:

- A folder of binary files that nobody can diff.
- A licence question for each file.
- An audio editor for each change.

When the game generates the sounds, a sound changes when a number changes.

## One oscillator with an envelope

```zig
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
```

*Quoted from the source: `Layer` from `examples/lane-dodger/src/audio/synth.zig`.*

Each layer has a frequency sweep, an amplitude envelope, and an optional low
pass. The low pass removes the high hiss from noise. `delay` starts a layer
later than the others. The arpeggios use `delay`, thus they need no sequencer
code.

The coin has two layers: a triangle, and a quieter sine one octave higher.

```zig
/// The five sounds of the game. The pitch for the combo steps changes at
/// playback, and is not part of the samples. Thus the game has one coin sound
/// and not eight.
pub const coin: []const Layer = &.{
    .{ .shape = .triangle, .from = 900, .to = 1350, .duration = 0.085, .gain = 0.55 },
    .{ .shape = .sine, .from = 1800, .to = 2700, .duration = 0.07, .gain = 0.22 },
};
```

*Quoted from the source: `coin` from `examples/lane-dodger/src/audio/synth.zig`.*

The crash has six layers. The last three layers are the descending triad that plays
over the game over screen:

```zig
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
```

*Quoted from the source: `crash` from `examples/lane-dodger/src/audio/synth.zig`.*

The six layers are one sound, and not two sounds. As two sounds, the thud would
play at impact and the sting would play when the retry prompt appears. Then the
code must record if the sting played yet, for a run that is already over. A layer
can have a delay, thus the pause is in the waveform.

## The renderer

```zig
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
```

*Quoted from the source: `render` from `examples/lane-dodger/src/audio/synth.zig`.*

The frequency sweep is exponential and not linear. Pitch is logarithmic. Thus a
linear sweep sounds as if it becomes faster near the end.

The renderer adds the layers together, then soft clips the sum with `tanh`. It
does not clamp the sum. Layers on top of each other go past the limit, and a
clamp cuts the peaks flat. You hear the flat peaks as distortion.

## The envelope, and the click

```zig
fn envelope(t: f32, layer: Layer) f32 {
    if (t < layer.attack) return t / layer.attack;
    const remaining = layer.duration - layer.attack;
    if (remaining <= 0) return 0;
    const decayed = 1 - (t - layer.attack) / remaining;
    if (decayed <= 0) return 0;
    return std.math.pow(f32, decayed, layer.curve);
}
```

*Quoted from the source: `envelope` from `examples/lane-dodger/src/audio/synth.zig`.*

The envelope is exactly zero at the two ends of each layer.

If a clip starts at full amplitude, the clip starts with a step. The step goes
from silence to the value of the waveform at that point. A step of this type is
a broadband impulse. The speaker plays it as a click, and the click is usually
louder than the effect. The same problem occurs at the end.

A fade in of four
milliseconds is sufficient. The decay has a shape that stops at zero, and the
code does not cut the decay at zero.

## Test a waveform

The synthesiser contains no raylib types. It fills a buffer with samples and
stops. Thus the tests check the sounds without an audio device. CI has no
speakers.

```zig
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
```

*Quoted from the source: `no sound begins or ends with a click` from `examples/lane-dodger/src/audio/synth.zig`.*

The next test checks the mix. The exact frequencies are a matter of taste, and
they can change. The relation between the sounds must not change. The crash is
the low, long and loud sound. The lane tick plays on each input, and it must not
be louder than a pickup.

```zig
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
```

*Quoted from the source: `the sounds sit in the right places against each other` from `examples/lane-dodger/src/audio/synth.zig`.*

Here, brightness is the number of zero crossings each second. This number is
only an approximate estimate of pitch. But it is sufficient to tell a chime from
a thud.

The measurements show that the five sounds are as intended. The coin is at
approximately 1130 Hz for 85 ms. The crash lasts 900 ms, with 81 percent of its
energy below 500 Hz. The lane tick is the shortest and the quietest sound. If you
prefer to listen, `zig build sounds` writes all of the sounds as `.wav` files.

## Play the sounds

```zig
/// One sound and a few aliases of it, played round robin.
///
/// If a sound already plays, raylib starts that sound again from the start.
/// Thus one handle can make only one note at a time. Coins arrive quickly, one
/// after the other. With one handle, each coin sound would stop the sound of
/// the previous coin. The aliases fix this problem. They use the same sample
/// data, and each alias has its own playback position.
const Voice = struct {
    /// Four is sufficient for the fastest series of coins that the spacing
    /// allows.
    const max_aliases = 4;

    sounds: [max_aliases]rl.Sound = undefined,
    count: usize = 0,
    next: usize = 0,

    fn load(layers: []const synth.Layer, scratch: []i16, aliases: usize, seed: u64) Voice {
        const written = synth.render(layers, scratch, seed);
        const wave: rl.Wave = .{
            .frameCount = @intCast(written),
            .sampleRate = synth.sample_rate,
            .sampleSize = 16,
            .channels = 1,
            .data = @ptrCast(scratch.ptr),
        };
        // raylib converts the frames and copies them into its own buffer. Thus
        // the code can use the scratch array again for the next sound.
        var voice: Voice = .{ .count = @min(aliases, max_aliases) };
        voice.sounds[0] = rl.LoadSoundFromWave(wave);
        for (1..voice.count) |i| voice.sounds[i] = rl.LoadSoundAlias(voice.sounds[0]);
        return voice;
    }

    fn play(self: *Voice, volume: f32, pitch: f32) void {
        if (self.count == 0) return;
        const sound = self.sounds[self.next];
        self.next = (self.next + 1) % self.count;
        rl.SetSoundVolume(sound, volume);
        rl.SetSoundPitch(sound, pitch);
        rl.PlaySound(sound);
    }
};
```

*Quoted from the source: `Voice` from `examples/lane-dodger/src/platform/audio.zig`.*

If a sound already plays, raylib starts that sound again from the start. Thus one
handle can make only one note at a time. During a combo, coins arrive quickly,
one after the other. Each coin would stop the sound of the previous coin. An
alias uses the same sample data as the sound, but each alias has its own
playback position.

The combo ladder is a pitch multiplier on the one coin sound. It is not eight
recordings:

```zig
    /// The one entry point that the game uses. It takes the same events as the
    /// particles and the screen shake.
    pub fn onEvent(self: *Audio, event: sim.Event) void {
        switch (event) {
            .coin => |c| {
                // Each combo step increases the pitch of the one coin sound.
                // Thus the game does not need eight coin sounds.
                // A semitone is 2^(1/12). This value is a little less than one
                // semitone for each step. Thus a full combo ends approximately
                // a fifth above its start.
                const step = std.math.pow(f32, 2.0, @as(f32, @floatFromInt(c.combo - 1)) / 14.0);
                self.cue(.coin, 0.85, step);
            },
            .near_miss => self.cue(.near_miss, 0.6, 1),
            .lane_changed => self.cue(.lane, 0.5, 1),
            .crashed => self.cue(.crash, 1, 1),
            .started => self.cue(.start, 0.8, 1),
            .coin_missed => {},
        }
    }
```

*Quoted from the source: `onEvent` from `examples/lane-dodger/src/platform/audio.zig`.*

## Optional at runtime

The device does not open in these cases:

- A machine with no sound card.
- A container with no ALSA.
- A browser tab that nobody clicked yet.

In each of these cases, each call above does nothing.

```zig
    /// Opens the device and renders each sound into it. You can safely call
    /// this function when no device exists. Then `ready` stays false, and all
    /// other calls do nothing.
    pub fn init(seed: u64) Audio {
        var audio: Audio = .{};
        rl.InitAudioDevice();
        if (!rl.IsAudioDeviceReady()) return audio;
        audio.ready = true;

        // One buffer for all sounds, because `LoadSoundFromWave` copies.
        var scratch: [synth.max_samples]i16 = undefined;
        const table = .{
            .{ Cue.coin, synth.coin, 4 },
            .{ Cue.near_miss, synth.near_miss, 2 },
            .{ Cue.lane, synth.lane, 3 },
            .{ Cue.crash, synth.crash, 1 },
            .{ Cue.start, synth.start, 1 },
        };
        inline for (table) |entry| {
            audio.voices.set(entry[0], .load(entry[1], &scratch, entry[2], seed));
        }

        rl.SetMasterVolume(0.55);
        return audio;
    }
```

*Quoted from the source: `init` from `examples/lane-dodger/src/platform/audio.zig`.*

The sound in this game is decoration. Thus the game must start when a mixer does
not open. To check this, the real binary runs with an ALSA configuration that has
an error on purpose.

The sound reads the same [event stream](https://www.ziglang.in/learn/lane-dodger/entities/) as the
particles. The tests that were already there continued to pass during the work on the
sound.
