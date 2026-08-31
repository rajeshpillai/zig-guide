//! Window, loop, and the wiring between them and the game.
//!
//! The interesting part is the loop. Real time arrives in whatever lumps the
//! display and the scheduler produce; the simulation only ever advances in
//! fixed 1/120 s ticks. Leftover time is carried in an accumulator and shows up
//! as `alpha`, which the renderer uses to draw between the last two ticks. So
//! the game plays identically on a 60 Hz laptop and a 165 Hz monitor, and a
//! dropped frame costs smoothness rather than changing the physics.

const std = @import("std");
const builtin = @import("builtin");
const rl = @import("rl");
const sim = @import("sim");

const draw = @import("render/draw.zig");
const palette = @import("render/palette.zig");
const particles = @import("render/particles.zig");
const input = @import("platform/input.zig");
const Audio = @import("platform/audio.zig").Audio;
const build_options = @import("build_options");

const config = sim.config;
const bot = sim.bot;

/// Largest real-time step we will believe. Past this the game was paused, the
/// laptop was asleep, or a breakpoint was hit; catching up on ten seconds of
/// ticks would only bury the player.
const max_frame_time: f32 = 0.25;

const Shake = struct {
    amount: f32 = 0,
    rng: sim.Rng,

    fn kick(self: *Shake, amount: f32) void {
        self.amount = @max(self.amount, amount);
    }

    fn update(self: *Shake, dt: f32) void {
        self.amount *= std.math.exp(-dt * 8.5);
        if (self.amount < 0.05) self.amount = 0;
    }

    fn apply(self: *Shake, view: *draw.View) void {
        if (self.amount == 0) return;
        view.shake_x = (self.rng.float() - 0.5) * 2 * self.amount * view.scale;
        view.shake_y = (self.rng.float() - 0.5) * 2 * self.amount * view.scale;
    }
};

/// Turn what the simulation reported into what the player sees and feels.
/// Nothing here can change the outcome of the run, which is the point.
fn react(
    world: *const sim.World,
    system: *particles.System,
    shake: *Shake,
    audio: ?*Audio,
) void {
    if (audio) |sound| {
        for (world.events.slice()) |event| sound.onEvent(event);
    }
    for (world.events.slice()) |event| switch (event) {
        .coin => |c| {
            system.burst(c.x, c.y, 10, palette.coin, 190);
            shake.kick(1.5 + @as(f32, @floatFromInt(c.combo)) * 0.4);
        },
        .near_miss => |n| {
            system.graze(n.x, n.y);
            shake.kick(3);
        },
        .crashed => |c| {
            system.debris(c.x, c.y);
            shake.kick(16);
        },
        .lane_changed => |l| {
            const direction: f32 = if (l.to > l.from) 1 else -1;
            system.dust(world.player.x, config.player_y, direction);
        },
        .coin_missed, .started => {},
    };
}

/// Advance a world by whole ticks, reacting to what each one reports.
fn advance(
    world: *sim.World,
    system: *particles.System,
    shake: *Shake,
    audio: ?*Audio,
    accumulator: *f32,
    latch: ?*input.Latch,
) void {
    while (accumulator.* >= config.tick_dt) {
        accumulator.* -= config.tick_dt;
        const tick_input = if (latch) |l| l.take() else bot.play(world);
        world.step(tick_input);
        react(world, system, shake, audio);
        world.events.reset();
    }
}

/// Everything a frame needs, in one place.
///
/// This is a struct rather than a pile of locals in `main` for one reason: on
/// the web the browser owns the loop. Emscripten calls a function once per
/// animation frame and never returns into our code, so there is nowhere for a
/// `while` loop to live and nothing for locals to live in. Splitting "one
/// frame" out from "keep doing frames" is what lets the same game run under a
/// loop we drive and a loop we do not.
const Game = struct {
    world: sim.World,
    /// The title screen plays itself. Same rules, same generator, driven by
    /// the policy the tests use to prove the course is fair.
    demo: sim.World,
    system: particles.System,
    shake: Shake,
    audio: Audio,
    latch: input.Latch,
    accumulator: f32 = 0,
    frames: usize = 0,

    fn init(seed: u64) Game {
        var fresh: Game = .{
            .world = .init(seed),
            .demo = .init(seed ^ 0x9E3779B97F4A7C15),
            .system = .init(seed),
            .shake = .{ .rng = .init(seed, 7) },
            .audio = if (build_options.audio) .init(seed) else .{},
            .latch = .{},
        };
        fresh.demo.start();
        if (build_options.auto_frames != null and build_options.demo != .title) {
            fresh.world.start();
        }
        return fresh;
    }

    /// True once the headless smoke run has done its frames.
    fn finished(self: *const Game) bool {
        const limit = build_options.auto_frames orelse return false;
        return self.frames >= limit;
    }

    fn frame(self: *Game) void {
        self.frames += 1;

        const auto_frames = build_options.auto_frames;
        const demo_mode = build_options.demo;

        const dt = @min(rl.GetFrameTime(), max_frame_time);
        self.accumulator += dt;

        if (auto_frames == null) {
            self.latch.poll();
            // Mute is a platform concern, not a rule of the game, so it never
            // reaches the simulation.
            if (rl.IsKeyPressed(rl.KEY_M)) self.audio.toggleMute();
        }
        const attract = self.world.phase == .ready;

        if (attract) {
            // Keep the demo alive so the title screen never sits on a wreck.
            if (self.demo.phase == .dead and self.demo.death_time >= config.death_hold) {
                self.demo.start();
            }
            var demo_accumulator = self.accumulator;
            // The attract mode is silent. A title screen that pings every
            // time the bot takes a coin is a title screen people mute.
            advance(&self.demo, &self.system, &self.shake, null, &demo_accumulator, null);
            // The player's world still needs the confirm press.
            while (self.accumulator >= config.tick_dt) {
                self.accumulator -= config.tick_dt;
                self.world.step(self.latch.take());
                // The start chime belongs to the player's world, not the demo.
                for (self.world.events.slice()) |event| self.audio.onEvent(event);
                self.world.events.reset();
            }
            if (self.world.phase == .playing) {
                // Starting for real: clear the demo's debris.
                self.system.clear();
                self.shake.amount = 0;
            }
        } else if (auto_frames != null and demo_mode == .crash) {
            // Nobody steers, so the first block ends the run and the game over
            // screen is what gets photographed.
            while (self.accumulator >= config.tick_dt) {
                self.accumulator -= config.tick_dt;
                self.world.step(.none);
                react(&self.world, &self.system, &self.shake, &self.audio);
                self.world.events.reset();
            }
        } else if (auto_frames != null) {
            advance(&self.world, &self.system, &self.shake, &self.audio, &self.accumulator, null);
        } else {
            advance(&self.world, &self.system, &self.shake, &self.audio, &self.accumulator, &self.latch);
        }

        const shown: *const sim.World = if (attract) &self.demo else &self.world;
        self.system.update(dt);
        self.shake.update(dt);

        var view: draw.View = .init(
            @floatFromInt(rl.GetScreenWidth()),
            @floatFromInt(rl.GetScreenHeight()),
        );
        self.shake.apply(&view);
        const alpha = self.accumulator / config.tick_dt;

        rl.BeginDrawing();
        draw.frame(shown, &self.system, view, alpha, shown.distance, !attract);
        if (attract) {
            drawTitle(view, self.world.best);
        } else if (self.world.phase == .dead) {
            drawGameOver(view, &self.world);
        }
        rl.EndDrawing();
    }
};

/// On the web this outlives `main`, which returns immediately once the browser
/// takes over the loop. A local would be gone by the first frame.
var game: Game = undefined;

const web = builtin.target.os.tag == .emscripten;

extern fn emscripten_set_main_loop(
    callback: *const fn () callconv(.c) void,
    fps: c_int,
    simulate_infinite_loop: c_int,
) void;

fn webFrame() callconv(.c) void {
    game.frame();
}

/// Emscripten links the program with `emcc`, and emcc wants a C `main`. Zig's
/// own `main` is reached through std's start code, which a static library does
/// not carry, so on the web the entry point is exported by hand.
fn cMain(argc: c_int, argv: [*c][*c]u8) callconv(.c) c_int {
    _ = argc;
    _ = argv;
    run();
    return 0;
}

comptime {
    if (web) @export(&cMain, .{ .name = "main", .linkage = .strong });
}

pub fn main() void {
    run();
}

fn run() void {
    // A resizable window on the desktop, and deliberately not on the web.
    //
    // raylib's web resize callback sets the canvas backing store to
    // `window.innerWidth` by `window.innerHeight`: the whole browser window,
    // not the element the canvas actually occupies. On a page where the canvas
    // is one column of a chapter, the buffer ends up several times wider than
    // the box it is displayed in. The letterbox here then centres the field
    // inside that buffer and CSS squashes the result, so the game renders as a
    // narrow strip down the middle. Leaving the flag off keeps the buffer the
    // size `InitWindow` asked for, and the page scales it with CSS.
    const resizable = if (web) 0 else rl.FLAG_WINDOW_RESIZABLE;
    rl.SetConfigFlags(rl.FLAG_VSYNC_HINT | rl.FLAG_MSAA_4X_HINT | resizable);
    rl.SetTraceLogLevel(rl.LOG_WARNING);
    rl.InitWindow(540, 960, "Lane Dodger");
    if (!web) rl.SetWindowMinSize(320, 480);

    // Entropy is the platform's job, not the simulation's. raylib seeds its
    // own generator from the clock during InitWindow, and this is the one
    // place a fresh run gets to be unpredictable; everything downstream of the
    // seed is exactly reproducible.
    //
    // Sixteen bits at a time: raylib computes its range as `max - min + 1` in
    // an int, so asking for the whole of i32 overflows and the result is
    // whatever the C library felt like.
    var seed: u64 = 0;
    for (0..4) |_| seed = (seed << 16) | @as(u64, @intCast(rl.GetRandomValue(0, 0xFFFF)));

    game = .init(seed);

    if (web) {
        // Hands the loop to the browser and does not come back. Passing 0 for
        // the frame rate means "use requestAnimationFrame", which is the only
        // way to be in step with the display.
        emscripten_set_main_loop(webFrame, 0, 1);
        return;
    }

    while (!rl.WindowShouldClose() and !game.finished()) game.frame();

    if (comptime build_options.screenshot) |path| rl.TakeScreenshot(path ++ "");
    game.audio.deinit();
    rl.CloseWindow();
}

fn drawTitle(view: draw.View, best: u32) void {
    draw.dim(view, 0.55);
    draw.panel(view, 150, 512, 0.86);
    draw.centred("LANE", view, 176, 64, palette.text);
    draw.centred("DODGER", view, 244, 64, palette.player);
    draw.centred("tap or press space", view, 356, 24, palette.text);
    draw.centred("A / D or arrows to switch lane", view, 402, 15, palette.text_dim);
    draw.centred("coins mark the safe lane", view, 426, 15, palette.text_dim);
    if (best > 0) {
        var buffer: [48]u8 = undefined;
        draw.centred(draw.fmtZ(&buffer, "BEST {d}", .{best}), view, 482, 24, palette.coin);
    }
}

fn drawGameOver(view: draw.View, world: *const sim.World) void {
    draw.dim(view, 0.58);
    draw.panel(view, 186, 512, 0.88);
    draw.centred("CRASHED", view, 210, 52, palette.block);

    var score_buffer: [48]u8 = undefined;
    draw.centred(draw.fmtZ(&score_buffer, "{d}", .{world.score}), view, 288, 72, palette.text);

    var coins_buffer: [48]u8 = undefined;
    const coin_word = if (world.coins == 1) "coin" else "coins";
    draw.centred(
        draw.fmtZ(&coins_buffer, "{d} {s}", .{ world.coins, coin_word }),
        view,
        372,
        22,
        palette.coin,
    );

    var best_buffer: [48]u8 = undefined;
    draw.centred(draw.fmtZ(&best_buffer, "BEST {d}", .{world.best}), view, 406, 22, palette.text_dim);

    if (world.death_time >= config.death_hold) {
        draw.centred("space to try again", view, 470, 22, palette.text);
    }
}
