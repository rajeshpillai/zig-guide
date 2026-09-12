# Build It From Scratch

> The order to write the files in, the two points where you can stop and check, and what to do when it does not build.

The other chapters explain what each piece does. This one is the order to write
them in.

There are two places you can stop and check your work. The first comes before
you have drawn anything, and it runs the whole game.

## What you need

Zig master. Not 0.16: the game uses `std.process.Init`, `std.Io.Dir`,
`std.mem.printSentinel` and `@splat` on arrays, all of which arrived after it.
`build.zig.zon` names the exact minimum.

```bash
zig version    # 0.17.0-dev.1676 or newer
```

Git, and a C compiler. On Debian or Ubuntu the game also needs the X
development headers:

```bash
sudo apt-get install libx11-dev libxrandr-dev libxinerama-dev \
                     libxi-dev libxcursor-dev libgl1-mesa-dev
```

No ALSA package. raylib's audio backend loads libasound at runtime rather than
including its header.

## Part one: the scaffolding

**1. Make the tree.**

```bash
mkdir -p lane-dodger/src/{sim,render,audio,platform,tools}
cd lane-dodger
```

**2. Ignore the raylib copy.** One line in `.gitignore`:

```
vendor/
```

The fetch script below is the record of which raylib this is. The copy it pulls
down is not, and it is 13 MB.

**3. The package file.**

<GameSource file="build.zig.zon" />

`zig build` will refuse the fingerprint and print the one to use. Paste that in.

Note what is *not* in `.dependencies`: raylib. That is the whole trick, and
[Vendoring raylib](https://www.ziglang.in/learn/lane-dodger/the-build/) explains why.

**4. The fetch script.**

<GameSource file="fetch-raylib.sh" lang="bash" />

```bash
chmod +x fetch-raylib.sh && ./fetch-raylib.sh
```

**5. The build.**

<GameSource file="build.zig" />

Nothing compiles yet. `build.zig` names files that do not exist, which is fine:
Zig only reads a source file when a step that needs it runs.

## Part two: the simulation

Nine files, in this order. Each one only uses the ones above it.

<GameFiles
  files={[
    { path: "src/sim/config.zig", what: "Every tunable number, and the field geometry.", chapter: "/learn/lane-dodger/the-world/", chapterTitle: "The World" },
    { path: "src/sim/rng.zig", what: "PCG32, so a seed replays exactly.", chapter: "/learn/lane-dodger/the-world/", chapterTitle: "The World" },
    { path: "src/sim/pool.zig", what: "Fixed-capacity storage with generational handles.", chapter: "/learn/lane-dodger/entities/", chapterTitle: "Handles, Not Pointers" },
    { path: "src/sim/sim.zig", what: "The world, the tick, collision and spawning.", chapter: "/learn/lane-dodger/the-world/", chapterTitle: "The World" },
    { path: "src/sim/bot.zig", what: "A policy that plays the game.", chapter: "/learn/lane-dodger/fair-by-design/", chapterTitle: "Difficulty You Can Prove" },
    { path: "src/sim/tests.zig", what: "The tests that play the game.", chapter: "/learn/lane-dodger/fair-by-design/", chapterTitle: "Difficulty You Can Prove" },
    { path: "src/render/palette.zig", what: "Colours as plain data, no raylib.", chapter: "/learn/lane-dodger/drawing/", chapterTitle: "Drawing It" },
    { path: "src/render/particles.zig", what: "Sparks and debris, using the same pool.", chapter: "/learn/lane-dodger/drawing/", chapterTitle: "Drawing It" },
    { path: "src/audio/synth.zig", what: "Five sound effects, generated.", chapter: "/learn/lane-dodger/sound/", chapterTitle: "Sound Without Sound Files" },
  ]}
/>

### The first checkpoint

```bash
zig build test
```

Fifty-five tests. A bot plays four minutes of the game at every seed, a second
bot plays it with a human reaction time, and two worlds replay from one seed and
are compared tick by tick.

You have not written a line of drawing code. There is no window, no `main.zig`,
and no audio device. The game is complete enough to be played and checked, and
that is the point the whole design is arranged around.

If this passes, the rules are right. Everything after it is presentation.

## Part three: the game you can see

Four more files.

<GameFiles
  files={[
    { path: "src/render/draw.zig", what: "The view transform and every raylib call.", chapter: "/learn/lane-dodger/drawing/", chapterTitle: "Drawing It" },
    { path: "src/platform/input.zig", what: "Keys and taps, latched once a frame.", chapter: "/learn/lane-dodger/input/", chapterTitle: "Input" },
    { path: "src/platform/audio.zig", what: "The audio device, and the sounds on it.", chapter: "/learn/lane-dodger/sound/", chapterTitle: "Sound Without Sound Files" },
    { path: "src/main.zig", what: "The window and the fixed timestep loop.", chapter: "/learn/lane-dodger/the-loop/", chapterTitle: "The Loop Takes No dt" },
  ]}
/>

```bash
zig build run -Doptimize=ReleaseFast
```

`A` and `D` or the arrow keys change lane. Space starts a run. `M` mutes.

## Optional

One more file writes the sound effects out as `.wav`, so you can listen to them
without playing up to the point that triggers each one.

<GameFiles
  files={[
    { path: "src/tools/dump_sounds.zig", what: "Renders the five clips to a directory.", chapter: "/learn/lane-dodger/sound/", chapterTitle: "Sound Without Sound Files" },
  ]}
/>

```bash
zig build sounds && ls zig-out/sounds
```

## How one tap becomes a frame

```
you press D
   |
   v
Latch.poll()            once per rendered frame, sets latch.right
   |
   v
Game.frame()            adds real elapsed time to the accumulator
   |
   v
while accumulator >= 1/120:
     Input = latch.take()      first tick gets the press, the rest get nothing
     World.step(input)         steer, move, spawn, collide, score
     react(events)             particles, screen shake, a note
   |
   v
alpha = accumulator / (1/120)      what is left over, less than one tick
   |
   v
draw.frame(world, alpha)    draws between the last two ticks
```

The press reaches exactly one tick. A frame that owes no ticks keeps it for the
next one. A frame that owes three gives it to the first.

## If it does not build

**`error: invalid fingerprint`.** Expected on the first run. Paste the value the
compiler prints into `build.zig.zon`.

**`error: unable to find module 'rl'`** or missing raylib headers. `fetch-raylib.sh`
has not run, or it ran in the wrong directory. Check that
`vendor/raylib/src/raylib.h` exists.

**`ld: cannot find -lX11`** and similar. The X development headers are missing.
Install the packages listed above. The plain runtime libraries are not enough;
you need the `-dev` ones.

**`root source file struct 'std' has no member named ...`.** Your Zig is too
old, or too new. This game tracks master, so both directions happen. Check
`zig version` against `minimum_zig_version`.

**Tests pass but the window is black.** You are on Wayland without XWayland, or
in a container with no display. Try `xvfb-run -a ./zig-out/bin/lane-dodger` to
confirm the program itself runs.

**It builds and plays badly.** Every number is in
[`src/sim/config.zig`](https://github.com/rajeshpillai/zig-guide/blob/main/examples/lane-dodger/src/sim/config.zig).
`lane_change_time` is the one to reach for first. Do not tighten the row spacing
by hand: `sim.zig` derives a floor from the other numbers, and
[the tests](https://www.ziglang.in/learn/lane-dodger/fair-by-design/) will tell you when you have gone
under it.
