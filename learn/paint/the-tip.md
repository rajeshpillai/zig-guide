# The Tip

> A dab is a disc with a fading edge. Squash it into an ellipse, turn it, and the same twenty lines draw a soft brush, a calligraphy nib and a ribbon.

A dab says where the brush touched and how big it was.

The **tip** decides which pixels that covers, and by how much.

The answer for each pixel is a number from 0 to 1 called its **coverage**. 1 means fully covered, 0 means untouched, and 0.5 means half.

The engine computes it for three kinds of tip:

- a round tip with a soft edge
- a flat tip, squashed into an ellipse
- a flat tip turned to an angle, fixed or following the stroke

## Which pixels to look at

A dab can only touch pixels within its radius of its centre.

So we visit the square around it, cut to the edges of the image, and nothing else:

<PaintSource file="src/engine/geometry.zig" decl="around" />

A 20-pixel dab looks at a 40 by 40 square: 1,600 pixels. The whole 640 by 400 image is 256,000. Visiting only the square is 160 times less work for every dab.

The square is computed in `f32` and clamped before it becomes an integer. A dab can start well outside the image. Converting a negative `f32` straight to a `u32` is illegal behaviour, which Zig checks in safe builds.

## A soft round tip

For a round tip, coverage depends only on the distance `d` from the dab's centre to the pixel's centre.

The brush's **hardness** is the solid part of the radius. With radius 20 and hardness 0.6:

- inside 12 pixels (0.6 × 20), coverage is 1
- from 12 to 20 pixels, it falls in a straight line from 1 to 0
- beyond 20 pixels, it is 0

At 16 pixels, halfway through the fading band, coverage is 0.5.

At hardness 1, the band would have no width at all, and the edge of every dab would be a staircase of whole pixels. So the band is never narrower than one pixel. That one pixel is enough to smooth the edge.

## Pixel centres

A pixel is a small square, not a point.

Pixel (5, 3) covers x from 5 to 6 and y from 3 to 4. Its centre is (5.5, 3.5).

The tip measures distance to the centre. If it used the corner instead, every dab would be drawn half a pixel up and to the left of where it was asked to be. The [Scaling and Resampling](https://www.ziglang.in/learn/graphics/resample/) chapter shows the same half-pixel mistake shifting a whole image.

## Squashing and turning

A calligraphy nib is not round. It is flat.

A flat tip is an ellipse: full width along one axis, and `aspect` times that along the other. With radius 20 and aspect 0.25, the tip is 40 pixels wide and 10 high.

To draw an ellipse, we turn the problem back into a circle.

Take the pixel's offset from the centre, `dx` and `dy`. Turn it by the tip's angle, so `u` runs along the tip and `v` across it. Then divide `v` by the aspect.

A point on the edge of the ellipse now lies exactly on the circle of the original radius, and the round tip's coverage rule works unchanged.

Here is the whole tip, all three kinds in one function:

<PaintSource file="src/engine/mask.zig" decl="stamp" />

`@cos` and `@sin` are computed once per dab, not once per pixel. A 20-pixel dab visits 1,600 pixels and uses the same two numbers for all of them.

## Following the direction

A nib at a fixed angle gives calligraphy. Lines along the nib come out thin and lines across it come out wide, without the pressure changing at all. That is the Calligraphy brush in the studio, held at −45 degrees.

A tip can also turn with the stroke.

The stroke already knows its direction. Each `move` computes it from the segment it walks:

```zig
s.direction = std.math.atan2(b.y - a.y, b.x - a.x);
```

`atan2` takes the change in y and the change in x and returns the angle, from −π to π. Moving right gives 0. Moving down the page gives π/2, a quarter turn, because y grows downwards on a screen.

With `follow_direction`, the dab's angle is that direction plus the brush's own angle. At 0 the flat tip lies along the stroke and draws a thin line. At 90 it lies across the stroke and draws a broad ribbon. That is the Ribbon brush.

## Checks

The soft tip from the example: solid to 12 pixels, half at 16, empty past 20.

<PaintSource file="src/engine/mask.zig" decl="radius 20, hardness 0.6 is solid to 12 and half at 16" />

The test centres the dab on a pixel corner, so the pixel at offset `k` has its centre `k + 0.5` pixels away. That is why the checks use 11, 15 and 20.

The flat tip, then the same tip turned a quarter turn:

<PaintSource file="src/engine/mask.zig" decl="aspect 0.25 makes a tip 40 wide and 10 high" />

And a dab mostly outside the image, which must touch only what is inside:

<PaintSource file="src/engine/mask.zig" decl="a dab past the edge touches nothing outside the image" />

## Explain before reading the answer

The Calligraphy brush has an aspect of 0.2 and an angle of −45 degrees.

You draw a line from the bottom left to the top right of the page. Is it thin or wide?

Thin. On screen, y grows downwards, so −45 degrees points up and to the right. That is the direction you are drawing in. The long side of the nib lies along the line, and the line is only as wide as the short side.
