# Lane Dodger

A hyper casual endless runner in Zig, drawn with raylib. Three lanes, one
button's worth of decision, and a difficulty curve that never stops tightening.

```
./fetch-raylib.sh     # once: vendor raylib's C at a pinned commit
zig build run         # play it
zig build test        # 55 tests, no window or speakers needed
zig build sounds      # write the sound effects to zig-out/sounds as .wav
```

For the browser version, with an activated [emsdk](https://emscripten.org) on
`$EMSDK` (or passed as `-Demsdk=`):

```
zig build web -Doptimize=ReleaseFast
python3 -m http.server -d zig-out/web 8080
```

That writes `index.html`, `lane-dodger.js` and a 128 KB `lane-dodger.wasm` into
`zig-out/web`, which is playable as it stands.

## Playing

`A` / `D` or the arrow keys switch lane, or tap the left and right halves of the
window. `M` mutes. Coins are always placed in a lane the oncoming row leaves open, so
following the coins and playing correctly are the same thing. That is the whole
tutorial, and there is no text explaining it.

## How it is put together

```
src/
  sim/        the rules. imports nothing.
    config.zig    every tunable number
    sim.zig       the world and its one step function
    pool.zig      fixed-capacity storage with generational handles
    rng.zig       PCG32, so a seed replays exactly
    bot.zig       a policy that plays the game
    tests.zig     tests that play the game and never open a window
  render/     what it looks like. reads the world, never writes it.
  audio/      what it sounds like. synth.zig holds no raylib either.
  platform/   raylib input and the audio device
  tools/      dump_sounds.zig, behind `zig build sounds`
  main.zig    window and the fixed timestep loop
```

Three decisions shape everything else.

**The simulation imports nothing.** No raylib, no clock, no allocator. It is a
function from a seed and a list of inputs to a list of states. That is what lets
every rule be tested by playing the game rather than by looking at it, and it is
the same reason the networking chapters of this guide parse from a `Reader`
instead of a socket.

**`step` takes no `dt`.** It advances one fixed 1/120 s tick, always. The loop in
`main.zig` accumulates real time and calls it a whole number of times, and the
renderer interpolates the leftover. A variable timestep would make the same
inputs produce different runs on different machines, which costs the replay
tests and, in a game scored on survival, turns a slow frame into an advantage.

**The row spacing is derived, not tuned.** There is a hard floor under it: the
player must be able to cross the board between two rows, and cannot start while
a row is level with them. `sim.rowGapSeconds` computes that floor and decays
towards it without reaching it, so the game gets harder for as long as anyone
keeps playing and stays winnable the whole time. Spacing rows any tighter would
break the game *silently*, because every row would still leave a lane open, just
not one anybody could reach.

## Sound

There are no audio files here. The five effects are synthesised at startup:
`audio/synth.zig` stacks a few oscillators with envelopes and fills a buffer
with 16-bit samples, and `platform/audio.zig` hands that to raylib. Six hundred
lines of arithmetic instead of a folder of `.wav`, which keeps the whole game a
text tree, makes a sound tunable by changing a number, and avoids the licensing
question that comes with every sample pack.

The synthesiser holds no raylib types, so the waveforms are tested without an
audio device: that every clip is audible, that none of them clips flat against
the rail, that the crash is the low long one and the lane tick is the short
quiet one, and that nothing starts or ends partway up a waveform. That last one
matters more than it sounds. A clip that does not begin and end at zero begins
and ends with a step, and a step is a click that is louder and more irritating
than the effect it is attached to.

Adding sound touched the simulation not at all. It reads the same events the
particles and the screen shake read, which is what that indirection was for:

```zig
.coin => |c| {
    const step = std.math.pow(f32, 2.0, @as(f32, @floatFromInt(c.combo - 1)) / 14.0);
    self.cue(.coin, 0.85, step);
},
```

The combo ladder is a pitch multiplier on one sound rather than eight
recordings. Audio is also entirely optional at runtime: no sound card, no ALSA
in the container, no click in the browser tab yet, and every call turns into
nothing rather than refusing to start.

## What the tests actually check

The ones worth knowing about:

- **`solvable course`** plays four minutes at 24 seeds with the bot at the
  controls and asserts it never crashes. This is the real proof that the
  generator is fair, and it is how the off-by-one-body bug in the bot was found:
  it steered into blocks whose centres were behind the player but whose bodies
  still overlapped.
- **`a run lasts about as long as a hyper casual run should`** puts a reaction
  delay in front of the same policy and checks the mean run length lands in a
  band. The bot has no reaction time, so a course only the bot can run would
  still pass every other test. This one says whether a person can play it.
- **`replay`** runs two worlds from one seed and one input script and asserts
  they agree on every tick.
- **`the row spacing never falls to the unwinnable floor`** sweeps an hour of
  simulated time.

## The browser build

Zig compiles the game and raylib's C to a static library for
`wasm32-emscripten`, and `emcc` links it, because the JavaScript glue, the GL
context and the canvas plumbing are things only Emscripten knows how to emit.

Two things about it are worth knowing, because both fail quietly.

**The browser owns the loop.** `emscripten_set_main_loop` calls a function once
per animation frame and never returns into our code, so there is nowhere for a
`while` loop to live. That is why `main.zig` has a `Game` struct with a `frame`
method: "one frame" and "keep doing frames" are separate, and only the second
one differs between a desktop window and a canvas.

**raylib here is built against GLES 3**, which emits `#version 300 es` shaders,
and those need a WebGL 2 context. Emscripten creates a WebGL 1 one unless told
otherwise, and the symptom is a game that loads, runs, reports no error and
compiles not a single shader. `-sMIN_WEBGL_VERSION=2` is the fix.

## raylib

`fetch-raylib.sh` vendors raylib's C sources at a pinned commit into `vendor/`,
which is git-ignored. `build.zig` compiles them directly.

raylib ships a good `build.zig` and this deliberately does not use it. Naming a
package in `build.zig.zon` makes the build runner import that package's
`build.zig`, so a dependency whose build script has not caught up with Zig
master fails the build before any of our code is compiled. raylib's had exactly
that problem on the Zig this repo tracks, and so did `raylib-zig`. The C does
not move nearly as fast, so we compile it ourselves and own the forty lines.

## Checking it without a keyboard

```
zig build -Dframes=600 -Ddemo=play  -Dshot=play.png   # sound off by default
zig build -Dframes=200 -Ddemo=title -Dshot=title.png
zig build -Dframes=900 -Ddemo=crash -Dshot=crash.png
xvfb-run -a -s "-screen 0 640x1100x24" ./zig-out/bin/lane-dodger
```

`-Dframes` plays that many frames with the bot driving and then exits, and
`-Ddemo` picks which screen it ends up on. Enough for CI to prove the game still
builds, runs and draws. Sound is off in that mode; `-Daudio=true` puts it back,
which is how the no-sound-card path gets exercised.
