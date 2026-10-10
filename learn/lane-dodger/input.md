# Input

> Presses latched once per frame and handed to exactly one tick, and why a held key must not cross the board.

The simulation runs at a fixed 120 Hz. The window runs at whatever the display
does. Those do not divide evenly, so a rendered frame may owe the simulation
zero ticks, or one, or three.

A press has to reach exactly one of them. If a press is dropped, the game
ignores the player. If it is repeated, one tap crosses three lanes.

<GameSource file="src/platform/input.zig" decl="Latch" />

`poll` runs once per rendered frame, before the tick loop. `take` hands the
latched presses to one tick and clears them.

## Why the fields are booleans and not key states

`IsKeyPressed` is true on the frame a key goes down and false while it is held.
That is the behaviour the game wants. A held `D` should move one lane, not slide
across the board at a hundred lanes a second.

The simulation says so in its own type:

<GameSource file="src/sim/sim.zig" decl="Input" />

And a test holds the compiler to it:

<GameSource file="src/sim/tests.zig" decl="a held direction moves exactly one lane" />

## A frame that owes no ticks

If a frame produces no ticks, `take` is never called and the latch keeps its
presses for the next frame. A tap between two ticks is remembered rather than
lost.

If a frame produces three ticks, the first gets the press and the other two get
nothing. This works because `take` clears the latch.

## Touch

The same poll reads the mouse, and splits the window down the middle.

Tapping the left half steers left, tapping the right half steers right, and
either counts as the confirm that starts a run. That is all the control a phone
needs. It took one extra branch in `poll`, because the simulation already works
in lanes and not in keys.

## What the platform layer does not do

Mute is a keypress, and it never reaches the simulation:

```zig
if (rl.IsKeyPressed(rl.KEY_M)) self.audio.toggleMute();
```

Mute only affects the audio device. Nothing in `sim/` knows sound exists, and a
mute key inside the simulation would change that.
