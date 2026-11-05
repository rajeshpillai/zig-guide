# The Loop Takes No dt

> A fixed timestep, an accumulator, interpolation for the leftover time, and the split that the browser build needs.

The usual game loop reads the clock and gives the elapsed time to the world.

```zig
while (running) {
    const dt = getFrameTime();
    world.update(dt);   // do not do this
    draw(world);
}
```

This loop causes three problems.

**The same inputs do not give the same run.** The value of `dt` is the time that
the machine gave. A 60 Hz laptop and a 165 Hz monitor move the world in
different steps. If you add 1/60 sixty times, the result is not the same number
as when you add 1/165 one hundred and sixty-five times.

**A slow frame becomes an advantage.** The score in this game measures survival.
A frame that takes 50 ms moves the world 50 ms forward in one jump. The game
tests for collision at the two ends of that jump, and not between them. If the
game stops for a moment, the player can move through a block.

**No run can replay.** To report a crash, you must record a video of the crash.
A seed and a list of key presses do not make the same crash on a different
machine.

## Fixed steps

`step` has no `dt` parameter. It moves the world forward by one tick, and a tick
always has the same size.

```zig
    /// Move the world forward by one fixed tick.
    ///
    /// This function has no `dt` parameter, on purpose. With a variable
    /// timestep, the same inputs would give different runs on different
    /// machines. Then the replay tests below could not work. Also, in a game
    /// that gives points for survival time, a slow frame would become an
    /// advantage. The caller collects real time and calls this function a
    /// whole number of times. `src/main.zig` shows how.
    pub fn step(w: *World, input: Input) void {
        switch (w.phase) {
            .ready => if (input.confirm) w.start(),
            .playing => w.stepPlaying(input),
            .dead => {
                w.death_time += config.tick_dt;
                w.player.x_prev = w.player.x;
                w.driftEntities();
                if (w.death_time >= config.death_hold and input.confirm) w.start();
            },
        }
    }
```

*Quoted from the source: `step` from `examples/lane-dodger/src/sim/sim.zig`.*

A caller cannot use `step` incorrectly. A caller cannot get half a tick. To get
ten ticks, a caller calls `step` ten times.

The tick rate is 120 Hz. This rate is more than each common refresh rate. Thus
the simulation is never the cause when the motion of the game looks rough.

## The accumulator

Real time arrives in parts of different sizes. The loop saves the time and uses
it one tick at a time.

```zig
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
```

*Quoted from the source: `advance` from `examples/lane-dodger/src/main.zig`.*

The input goes to the first tick of the frame. The input for the other ticks is
empty. A key press is an edge trigger. If one press went to three ticks, one tap
would move the player across three lanes.

The loop clamps the frame time before the time goes into the accumulator.

```zig
/// The largest real-time step that the loop accepts. A larger step means that
/// the game was paused, the laptop was asleep, or a breakpoint stopped the
/// program. If the loop ran ten seconds of ticks at one time to recover the
/// time, the player would die before the player could react.
const max_frame_time: f32 = 0.25;
```

*Quoted from the source: `max_frame_time` from `examples/lane-dodger/src/main.zig`.*

Without the clamp, the loop can get ten seconds at one time. A paused game or a
laptop that wakes from sleep can cause this. Ten seconds is 1200 ticks. The time
to run these ticks gives another large `dt`, and that `dt` gives more ticks. The
game stops and does not respond, and it does not move forward. The usual name for
this problem is the spiral of death.

## The leftover time

After the tick loop, some time always remains, and this time is less than one
tick. If the renderer ignores this time, the game moves in visible steps at 120
Hz on a 165 Hz display.

Thus the loop tells the renderer how far it is into the next tick. The renderer
draws between the last two states.

```zig
const alpha = self.accumulator / config.tick_dt;
```

```zig
/// Interpolate between the last two simulation ticks. Without this, the game
/// moves in visible steps at 120 Hz on a 144 Hz display.
fn lerp(previous: f32, current: f32, alpha: f32) f32 {
    return previous + (current - previous) * alpha;
}
```

*Quoted from the source: `lerp` from `examples/lane-dodger/src/render/draw.zig`.*

Because the renderer draws between states, `Entity` has a `y_prev` field that no
rule reads. `y_prev` is not simulation state. The renderer needs it to draw a
frame between two ticks.

## One frame, not a loop

On the desktop, the loop is a `while` loop. In a browser, the loop cannot be a
`while` loop. Emscripten calls a function one time for each animation frame, and
Emscripten never returns into your code. A `while` loop cannot run there, and its
local variables have no place to live.

Thus the code keeps "one frame" separate from "run frames continuously". `Game`
is a struct with a `frame` method. Only the caller is different.

```zig
pub fn main() void {
    run();
}
```

*Quoted from the source: `main` from `examples/lane-dodger/src/main.zig`.*

The game state is a variable at file scope, and not a local variable.
`emscripten_set_main_loop` never returns. Thus a local variable in `main` does not
exist when the first frame starts.

Use this split also for a game that you never put in a browser. If you can call a
frame one time, you can also call it six hundred times. A bot can be at the
controls, with no open window. [The difficulty tests](https://www.ziglang.in/learn/lane-dodger/fair-by-design/)
use this method.
