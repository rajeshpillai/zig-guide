# Drawing It

> Field units mapped onto a window, the road, the entities, and a particle system that holds no raylib types.

The simulation works in a fixed 360 by 640 field. The window is whatever size
the reader dragged it to. One struct maps between them.

<GameSource file="src/render/draw.zig" decl="View" />

The scale is the smaller of the two ratios, so the field is letterboxed. A wider
window gets bars on the sides. It does not get more road.

That matters more than it looks. If the view stretched to fill the window, a
wide window would show blocks earlier and resizing would become a strategy.

`shake_x` and `shake_y` are added at the end of the transform, so screen shake
moves the whole field and costs nothing anywhere else.

## A frame

<GameSource file="src/render/draw.zig" decl="frame" />

The order is back to front: road, entities, particles, player, HUD. The world is
read and never written. Nothing in this file can change the outcome of a run.

## The road

<GameSource file="src/render/draw.zig" decl="drawRoad" />

The dashes scroll with the distance travelled. They are the only thing on screen
that shows speed when the field happens to be empty, and the field is empty more
often than you would think in the first few seconds.

## The entities

<GameSource file="src/render/draw.zig" decl="drawEntities" />

Each entity is drawn between its last two positions, using the `alpha` the
[loop](https://www.ziglang.in/learn/lane-dodger/the-loop/) hands down. Without that the game visibly
steps at 120 Hz on a faster display.

The coin spin is a squash on the width rather than a rotation. It bottoms out at
55 percent, and that floor is not cosmetic. An earlier version swept the full
range, so the coin turned edge on and disappeared for a few frames. A pickup the
player cannot see is a pickup they will not go for.

## The player

<GameSource file="src/render/draw.zig" decl="drawPlayer" />

The lean is computed from the distance between the target lane and the actual
position, which is exactly the gap
[the previous chapter](https://www.ziglang.in/learn/lane-dodger/the-world/) described. It costs three
lines and it is most of what makes the movement read as deliberate rather than
dragged.

## Colours are plain data

<GameSource file="src/render/palette.zig" decl="Color" />

No raylib type anywhere in that file. `draw.zig` converts at the edge:

<GameSource file="src/render/draw.zig" decl="color" />

The reason is the particle system below. It needs colours, and keeping raylib
out of it is what lets it be tested without a window.

## Particles

Particles are presentation. The simulation reports that a coin was collected.
This decides that means eight amber dots flying outwards.

<GameSource file="src/render/particles.zig" decl="System" />

It uses the same [pool](https://www.ziglang.in/learn/lane-dodger/entities/) the entities use, with a
different element type and a capacity of 256. Writing that pool generically
meant the renderer got fixed-capacity storage with no allocator for free.

A full pool drops new particles rather than making room. A dropped spark is
invisible. Stalling a frame to fit one in is not.

<GameSource file="src/render/particles.zig" decl="burst" />

Because none of this touches raylib, the behaviour is checked headlessly:
particles expire and free their slots, a full pool stays inside capacity, and
gravity pulls them down.

## Text over a moving field

The HUD sits at the top of the field, which is exactly where blocks enter. The
score spends part of every run on top of a bright red rectangle.

<GameSource file="src/render/draw.zig" decl="shadowed" />

A one pixel shadow is cheaper than reserving a strip of the playfield for the
HUD, and it keeps the whole field playable.
