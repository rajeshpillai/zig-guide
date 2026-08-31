//! The audio device, and the sounds the game plays on it.
//!
//! Everything here is optional at runtime. A machine with no sound card, a CI
//! runner with no ALSA, a browser tab that has not been clicked in yet: all of
//! those leave `ready` false, and every call below turns into nothing. A game
//! that refuses to start because it could not open a mixer is a worse game than
//! a silent one.
//!
//! This is also the only place that knows sound exists. The simulation reports
//! that a coin was collected; `main.zig` turns that into particles, screen
//! shake and a note. None of them can change the outcome of the run, which is
//! the property that made it safe to add sound to a finished game.

const std = @import("std");
const rl = @import("rl");
const sim = @import("sim");
const synth = @import("../audio/synth.zig");

const Cue = enum { coin, near_miss, lane, crash, start };

/// One sound plus a few aliases of it, played round robin.
///
/// raylib restarts a sound that is already playing, so a single handle can only
/// ever make one note. Coins arrive in quick succession and a combo that
/// silences itself is worse than no sound, hence the aliases: they share the
/// sample data and have their own playback position.
const Voice = struct {
    /// Four is enough for the fastest run of coins the spacing allows.
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
        // raylib converts and copies the frames into its own buffer, so the
        // scratch array is free to be reused for the next sound.
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

    /// Opens the device and renders every sound into it. Safe to call when
    /// there is no device; `ready` stays false and everything else no-ops.
    pub fn init(seed: u64) Audio {
        var audio: Audio = .{};
        rl.InitAudioDevice();
        if (!rl.IsAudioDeviceReady()) return audio;
        audio.ready = true;

        // One buffer, reused: `LoadSoundFromWave` copies.
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
        // Aliases first: they borrow the original's sample data.
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

    /// The one entry point the game uses. Takes the same events the particles
    /// and the screen shake take.
    pub fn onEvent(self: *Audio, event: sim.Event) void {
        switch (event) {
            .coin => |c| {
                // The combo ladder, as pitch rather than as eight recordings.
                // A semitone is 2^(1/12); this is a little under one per step,
                // so a full combo lands about a fifth above where it started.
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
