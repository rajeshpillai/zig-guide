# Strokes

> Pointer samples arrive at uneven distances. Walk the path between them, place a dab every few pixels, and carry the leftover distance into the next segment.

A brush stroke is a row of marks called **dabs**.

Each dab is one stamp of the brush tip. Put enough of them close together and they look like one continuous line, if they are spaced evenly.

## The obvious answer is wrong

The pointer reports where it is, again and again, while the button is held. Each report is a **sample**.

The obvious answer is one dab per sample.

That fails for a simple reason. Samples do not arrive at even distances.

The browser sends them when it gets round to it, about once per screen frame. A slow movement gives samples one or two pixels apart. A fast movement gives samples 40 pixels apart, with nothing in between.

So one dab per sample draws a solid line when you move slowly, and a row of separate dots when you move fast.

## Distance and lerp

We need two small tools first.

The distance between two points is the length of the straight line from one to the other:

<PaintSource file="src/engine/geometry.zig" decl="distance" />

From (10, 20) to (40, 60), the change in x is 30 and the change in y is 40. The distance is √(900 + 1600) = 50 pixels.

Moving backwards gives negative changes, but the same distance.

`lerp` finds the value a fraction `t` of the way from `a` to `b`:

<PaintSource file="src/engine/geometry.zig" decl="lerp" />

From 20 to 100, `t = 0.25` gives 40. `t = 0` gives 20 and `t = 1` gives 100.

`t = 1.5` gives 140, past the end. `lerp` does not clamp, and the stroke code never needs it to.

## Walking the path

The fix is to stop caring where the samples are.

Between two samples the pointer moved along a line. We walk along that line and put a dab every `gap` pixels.

The gap comes from the brush. It is a fraction of the radius, so a big brush puts its dabs further apart than a small one:

<PaintSource file="src/engine/stroke.zig" decl="gap" />

A spacing of 0.25 on a brush of radius 40 gives a gap of 10 pixels.

## The leftover distance

Walking each segment on its own still has a problem.

Say the gap is 10 and the pointer moves 6 pixels. No dab fits in 6 pixels.

Then it moves another 6. If each segment starts counting from zero, no dab fits in that one either. The pointer has moved 12 pixels and the stroke has no dab after the first.

So we remember how far we have walked since the last dab. That distance is called the **carry**.

After the first 6-pixel move, the carry is 6.

The next segment does not need a whole gap before its first dab. It needs only the 4 pixels that complete the interval: 10 − 6 = 4.

Here is `move`, the function each new sample goes through:

<PaintSource file="src/engine/stroke.zig" decl="move" />

`at` is the distance along this segment where the next dab goes. It starts at `step - s.carry`, which is the 4 pixels in our example.

The loop places a dab, adds a gap, and repeats while `at` still falls inside the segment.

When the loop ends, `at` has gone one gap past the last dab. So `at - step` is where the last dab was, and `d - (at - step)` is how far the segment ran on after it. That is the new carry.

After the loop, the carry is always less than one gap.

## Two smaller details

Two samples can arrive at exactly the same position. The distance is then 0, and `at / d` would be a division by zero, giving NaN. NaN in a position puts a dab nowhere and poisons every calculation after it. So `move` returns early when `d == 0`.

A stroke must also leave a mark when you click without moving. So `begin` places the first dab at the starting point, and resets the carry to 0:

<PaintSource file="src/engine/stroke.zig" decl="begin" />

## Where the dabs go

`move` does not draw anything. It calls `sink.dab(...)` and lets the caller decide.

`sink` is `anytype`, so any value with a `dab` method works. Zig checks this at compile time, separately for each type that is passed in.

The document passes a painter that stamps each dab into the stroke buffer. A test passes a recorder that only keeps a list:

<PaintSource file="src/engine/stroke.zig" decl="Recorder" />

The stroke code is the same in both. Only what happens to the dabs changes.

## Checks

The worked example from above, as a test. Three moves of 6 pixels with a gap of 10:

<PaintSource file="src/engine/stroke.zig" decl="carry after three moves of 6 pixels with a gap of 10 is 8" />

The first dab is at 0 and the second at 10, one gap apart. The second move, from 6 to 12, places it 4 pixels in.

The next test is the reason for the carry. It draws one 100-pixel move, then the same 100 pixels cut into moves of 3. Both must give the same dabs:

<PaintSource file="src/engine/stroke.zig" decl="the spacing does not depend on how the movement was cut up" />

Without the carry, the second stroke would put a dab at the end of every 3-pixel move, or at none of them.

And the repeated sample:

<PaintSource file="src/engine/stroke.zig" decl="a repeated sample adds no dab and does not divide by zero" />

## Recording and replaying

A stroke is just its list of samples.

Keep the list, and you can draw the stroke again. With the same brush it draws the same dabs. With a different brush it draws the same path in a new style.

The demo picture from the [first chapter](https://www.ziglang.in/learn/paint/a-paint-program/) is a replay of this kind. Its samples are written into the code, so a test can draw it and compare the pixels.

## Explain before reading the answer

You finish a stroke with a carry of 7, lift the pen, and start a new stroke somewhere else.

Should the new stroke start with a carry of 7?

No. The carry measures the distance since the last dab of this stroke. A new stroke has no last dab. It starts its own spacing, with a dab where the pen touches down, which is why `begin` sets `carry = 0`.
