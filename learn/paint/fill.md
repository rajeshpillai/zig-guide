# Fill

> A flood fill finds its region a few pixels at a time. A queue and a visited map do it in fixed memory, where recursion would run out of stack.

The Fill tool paints a whole area at once.

You click one pixel. Every pixel connected to it by the same colour changes to the new colour, and the fill stops at any other colour.

That set of pixels is the **region**. The work is finding it.

## The region is found a few pixels at a time

We cannot know the region's shape in advance. We only know the first pixel.

Its neighbours with the same colour are in the region too. Their neighbours with the same colour are in it as well, and so on.

So each pixel we accept can reveal more pixels to look at.

## Recursion is the short answer, and the wrong one

The shortest way to write this is a function that fills one pixel and then calls itself on its four neighbours.

It is short and it is wrong for a paint program.

Each call waits for the calls it makes, so the calls nest. Filling an empty 640 by 400 layer nests 256,000 calls deep. Each call needs some stack space, and a thread's stack is usually 8 MiB or less, and much less in a browser. The program stops partway through the fill.

## A queue and a visited map

Instead we keep a list of pixels still to look at, called a **queue**, and work through it from the front:

1. Put the clicked pixel in the queue.
2. Take the next pixel from the queue.
3. For each of its four neighbours: if it has the target colour and we have not seen it yet, mark it seen and add it to the queue.
4. Repeat from step 2 until the queue is empty.

The marks live in a **bit set**: one bit per pixel of the image. A 640 by 400 image needs 256,000 bits, which is 32,000 bytes.

<PaintSource file="src/engine/fill.zig" decl="find" />

## Why the queue never needs to grow

A pixel is marked when it goes into the queue, not when it comes out.

That small choice means no pixel can enter the queue twice. So the queue never holds more entries than the image has pixels, and we can allocate exactly that much up front.

And because nothing is ever removed from the front, there is no need to move anything. `head` is where we read and `tail` is where we write. Both only move forward.

For 640 by 400 the queue is 256,000 `u32` values, 1,024,000 bytes. It is freed when `find` returns.

## Four neighbours, and the fringe

The fill checks four neighbours: left, right, up and down.

So two pixels that touch only at a corner are not connected. A fill stops at a diagonal gap.

The match is also exact. A pixel is in the region only if all four of its bytes equal the starting pixel's.

The soft edge of a brush stroke is made of pixels that are partly covered, so none of them match exactly. A fill inside a soft circle stops before the edge and leaves a thin ring of the old colour. Paint programs offer a **tolerance** setting for this reason. This engine leaves it out to keep the region rule simple.

## Filling and undo

The document's `fillAt` finds the region, saves its bounding rectangle for undo, and changes every pixel in the region:

<PaintSource file="src/engine/document.zig" decl="fillAt" />

It also checks the colour first. Filling a region with the colour it already has would search the whole region and change nothing, and leave an undo step that does nothing.

`errdefer` in `find` matters here. If the queue cannot be allocated, the bit set that was already allocated is freed before the error goes back to the caller. A test checks this by failing each allocation in turn.

## Checks

A closed shape with a box inside it. The fill finds the 9 pixels around the box and not the one pixel inside it:

<PaintSource file="src/engine/fill.zig" decl="a closed shape fills inside and stops at its walls" />

The diagonal gap:

<PaintSource file="src/engine/fill.zig" decl="four neighbours do not leak through a diagonal gap" />

A whole empty 640 by 400 layer, the case recursion cannot do:

<PaintSource file="src/engine/fill.zig" decl="a whole empty 640 by 400 image fills without recursion" />

## Explain before reading the answer

A queue takes from the front. A **stack** takes from the back.

If `find` took the newest pixel instead of the oldest, would it still find the same region?

Yes. It would visit the pixels in a different order, going deep in one direction before coming back, but every pixel it can reach is still reached exactly once. The region is the same. Only the order of the visits changes.
