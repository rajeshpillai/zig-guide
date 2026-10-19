//! The window, the loop, and the connections between them and the game.
//!
//! The important part is the loop. Real time arrives in parts of different
//! sizes, from the display and the scheduler. The simulation moves forward
//! only in fixed ticks of 1/120 s. An accumulator keeps the leftover time, and
//! the leftover time becomes `alpha`. The renderer uses `alpha` to draw
//! between the last two ticks.
//!
//! Thus the game plays identically on a 60 Hz laptop and a 165 Hz monitor. A
//! dropped frame makes the motion less smooth, but it does not change the
//! physics.

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

/// The largest real-time step that the loop accepts. A larger step means that
/// the game was paused, the laptop was asleep, or a breakpoint stopped the
/// program. If the loop ran ten seconds of ticks at one time to recover the
/// time, the player would die before the player could react.
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

/// Change the reports from the simulation into what the player sees and
/// feels. No code here can change the result of the run.
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

/// Move a world forward by whole ticks, and react to the report of each tick.
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

/// All the data that a frame needs, in one place.
///
/// This is a struct and not local variables in `main`, because on the web the
/// browser owns the loop. Emscripten calls a function one time for each
/// animation frame, and never returns into this code. Thus a `while` loop has
/// no place to live, and local variables have no place to live. "One frame" is
/// separate from "run frames continuously". Thus the same game runs under the
/// loop in `main` and under the loop of the browser.
const Game = struct {
    world: sim.World,
    /// The title screen plays itself. It has the same rules and the same
    /// generator. The policy that the tests use to prove that the course is
    /// fair controls it.
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

    /// True when the headless smoke run completed its frames.
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
            // Mute is a function of the platform, and not a rule of the game.
            // Thus mute never gets to the simulation.
            if (rl.IsKeyPressed(rl.KEY_M)) self.audio.toggleMute();
        }
        const attract = self.world.phase == .ready;

        if (attract) {
            // Keep the demo alive. Then the title screen never stays on a crash.
            if (self.demo.phase == .dead and self.demo.death_time >= config.death_hold) {
                self.demo.start();
            }
            var demo_accumulator = self.accumulator;
            // The attract mode is silent. If the title screen played a sound
            // each time that the bot took a coin, people would turn off the
            // sound of the game.
            advance(&self.demo, &self.system, &self.shake, null, &demo_accumulator, null);
            // The world of the player still needs the confirm press.
            while (self.accumulator >= config.tick_dt) {
                self.accumulator -= config.tick_dt;
                self.world.step(self.latch.take());
                // The start chime is part of the world of the player, and not
                // part of the demo.
                for (self.world.events.slice()) |event| self.audio.onEvent(event);
                self.world.events.reset();
            }
            if (self.world.phase == .playing) {
                // The run of the player starts. Clear the particles and the
                // shake of the demo.
                self.system.clear();
                self.shake.amount = 0;
            }
        } else if (auto_frames != null and demo_mode == .crash) {
            // Nobody steers. Thus the first block stops the run, and the
            // screenshot shows the game over screen.
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

/// On the web, this variable lives longer than `main`. `main` returns
/// immediately when the browser takes control of the loop. A local variable
/// would not exist at the first frame.
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

/// Emscripten links the program with `emcc`, and emcc needs a C `main`. The
/// start code of std calls the Zig `main`, and a static library does not
/// contain that start code. Thus on the web, this code exports the entry point
/// by hand.
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
    // A resizable window on the desktop, and intentionally not on the web.
    //
    // The web resize callback of raylib sets the canvas backing store to
    // `window.innerWidth` by `window.innerHeight`. That is the full browser
    // window, and not the element of the canvas. On a page where the canvas is
    // one column of a chapter, the buffer becomes several times wider than its
    // box. The letterbox then centres the field in that buffer, and CSS makes
    // the result smaller. Thus the game shows as a narrow strip in the middle.
    // Without the flag, the buffer keeps the size from `InitWindow`, and the
    // page scales it with CSS.
    const resizable = if (web) 0 else rl.FLAG_WINDOW_RESIZABLE;
    rl.SetConfigFlags(rl.FLAG_VSYNC_HINT | rl.FLAG_MSAA_4X_HINT | resizable);
    rl.SetTraceLogLevel(rl.LOG_WARNING);
    rl.InitWindow(540, 960, "Lane Dodger");
    if (!web) rl.SetWindowMinSize(320, 480);

    // Entropy is the job of the platform, and not of the simulation. raylib
    // seeds its own generator from the clock during InitWindow. This is the
    // only place where a new run gets random values. After the seed, all of
    // the run is exactly reproducible.
    //
    // Sixteen bits at a time. raylib calculates its range as `max - min + 1`
    // in an int. Thus a request for the full range of i32 overflows, and
    // signed overflow is undefined behaviour in C.
    var seed: u64 = 0;
    for (0..4) |_| seed = (seed << 16) | @as(u64, @intCast(rl.GetRandomValue(0, 0xFFFF)));

    game = .init(seed);

    if (web) {
        // Gives the loop to the browser and does not return. A frame rate of
        // 0 means "use requestAnimationFrame". That is the only way to stay in
        // step with the display.
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
