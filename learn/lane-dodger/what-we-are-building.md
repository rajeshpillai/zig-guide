# A Game You Can Test

> A three lane endless runner that you can play here, and the one rule that lets you test the rest.

Press Play. To change lane, use the arrow keys or `A` and `D`. Space starts a
run. `M` stops the sound.

*Interactive: the game, compiled to WebAssembly. The same build that runs on the desktop, compiled to WebAssembly. It runs on the web page of this chapter.*

The game has three lanes. Blocks move toward you. Coins add to the score. The
game becomes faster until you lose. A run lasts approximately half a minute.

## Games are difficult to test

The behaviour of a game is inside a loop. The loop reads the keyboard, sends
commands to a GPU and runs sixty times each second. A test must not contain any
of these three things.

Thus most small games have no tests. The developer plays the game and adjusts
it. The difficulty becomes the level that the developer could play that week.

This game has fifty-five tests. No test needs a window.

## One rule makes the tests possible

The rules of the game are in one module. That module does not import raylib, a
library for windows, or a clock. The module never allocates. It changes a seed
and a list of inputs into a list of states.

```zig
/// Edge-triggered: each field means "pressed during this tick", not "held".
/// A key that the player holds must not slide the player across the board.
pub const Input = struct {
    left: bool = false,
    right: bool = false,
    confirm: bool = false,

    pub const none: Input = .{};
};
```

*Quoted from the source: `Input` from `examples/lane-dodger/src/sim/sim.zig`.*

All other code reads from that state. The renderer draws the world. The audio
code plays a note when an event occurs. The renderer and the audio code cannot
change the result of a run.

The [networking chapters](https://www.ziglang.in/learn/networking/) use the same design. Their
protocol code parses from a `Reader` and not from a socket. If code runs only
inside the full program, nobody tests that code.

## What the tests do

A bot plays the course for four minutes of game time at each seed. The bot must
never crash. If the generator can make a row that nobody can pass, this test
finds the row. The test also found a bug in the bot. The bot steered into blocks
whose centres were behind the player but whose bodies were not.

The same bot runs again with a delay before each action. The delay is a model of
human reaction time. The test checks the average length of a run. A machine with
no reaction time can survive a course, but that result does not tell you if a
person can play the course. This test found a difficulty curve that stopped its
increase after sixty seconds. A good player never lost.

A third test runs two worlds from one seed and one script of inputs. The test
compares the two worlds on each tick.

## Where the code is

```
src/
  sim/        the rules. imports nothing.
  render/     what it looks like. reads the world, never writes it.
  audio/      what it sounds like. holds no raylib either.
  platform/   raylib input and the audio device
  main.zig    window and the fixed timestep loop
```

The full project is on GitHub at
[examples/lane-dodger](https://github.com/rajeshpillai/zig-guide/tree/main/examples/lane-dodger).
Each code block in these chapters shows the path of its file, and the path is a
link to the file. The build of this page reads the blocks from disk. Thus a
chapter cannot describe a function that somebody deleted months ago.

The chapters explain the full game, in the order that you would build it.

## The chapters

- [Vendor raylib](https://www.ziglang.in/learn/lane-dodger/the-build/): how to add raylib to a Zig
  project. Also, why this project depends on the C of raylib and not on its
  build script.
- [The world](https://www.ziglang.in/learn/lane-dodger/the-world/): the field, the two positions of
  the player, and the order of work in a tick.
- [The loop](https://www.ziglang.in/learn/lane-dodger/the-loop/): a fixed timestep, and why `step`
  has no `dt` parameter.
- [Handles](https://www.ziglang.in/learn/lane-dodger/entities/): a pool of entities that never
  allocates. The code refers to an entity by a handle and not by a pointer.
- [Draw it](https://www.ziglang.in/learn/lane-dodger/drawing/): field units on a window, the road,
  and a particle system that does not use raylib.
- [Input](https://www.ziglang.in/learn/lane-dodger/input/): the game records key presses one time in
  each frame and gives them to exactly one tick.
- [Difficulty](https://www.ziglang.in/learn/lane-dodger/fair-by-design/): the space between rows comes
  from what is possible. Nobody adjusted it by feel.
- [Sound](https://www.ziglang.in/learn/lane-dodger/sound/): five effects, and no audio files.
- [Build it from scratch](https://www.ziglang.in/learn/lane-dodger/build-it/): the order in which to
  write the files, and the two points where you can stop and check your work.
