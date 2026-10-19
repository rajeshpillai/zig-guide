//! The audio device, and the sounds the game plays on it.
//!
//! All of this file is optional at runtime. In these cases, `ready` stays
//! false, and each call below does nothing:
//!
//! - A machine with no sound card.
//! - A CI runner with no ALSA.
//! - A browser tab that nobody clicked yet.
//!
//! A game that does not start because it cannot open a mixer is worse than a
//! silent game.
//!
//! This file is also the only place that knows that sound exists. The
//! simulation reports that the player collected a coin. `main.zig` changes
//! that report into particles, screen shake and a note. None of these can
//! change the result of the run. Because of this property, it was safe to add
//! sound to a game that was already complete.

const std = @import("std");
const rl = @import("rl");
const sim = @import("sim");
const synth = @import("../audio/synth.zig");

const Cue = enum { coin, near_miss, lane, crash, start };

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

pub const Audio = struct {
    ready: bool = false,
    muted: bool = false,
    voices: std.EnumArray(Cue, Voice) = .initFill(.{}),

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

    pub fn deinit(self: *Audio) void {
        if (!self.ready) return;
        // Unload the aliases first, because they use the sample data of the
        // original.
        var it = self.voices.iterator();
        while (it.next()) |entry| {
            const voice = entry.value;
            var i: usize = voice.count;
            while (i > 1) {
                i -= 1;
                rl.UnloadSoundAlias(voice.sounds[i]);
            }
            if (voice.count > 0) rl.UnloadSound(voice.sounds[0]);
        }
        rl.CloseAudioDevice();
    }

    pub fn toggleMute(self: *Audio) void {
        self.muted = !self.muted;
    }

    fn cue(self: *Audio, which: Cue, volume: f32, pitch: f32) void {
        if (!self.ready or self.muted) return;
        self.voices.getPtr(which).play(volume, pitch);
    }

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
};
