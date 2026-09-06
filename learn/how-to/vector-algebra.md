# Recipe: Vector Algebra

> Dot, length, normalize, and cross on @Vector, written like math instead of loops.

## The problem

You are doing 3D work (graphics, physics, a game) and need the four
staples: dot product, length, normalization, and cross product. Written as
scalar loops they are noisy and easy to get subtly wrong. Zig's `@Vector`
lets you write them with ordinary operators, so the code reads like the math
it implements and the compiler emits SIMD.

Two steps trip people up: collapsing a vector back to a single number, and
pushing a single number back out into a vector.

## The plan

1. Pick a vector type. `@Vector(3, f32)` is three `f32` lanes.
2. Dot product is `@reduce(.Add, a * b)`: multiply lane-by-lane, then add the
   lanes together.
3. Length is `sqrt(dot(v, v))`, which reuses the dot you already wrote.
4. Normalize divides by the length. `@splat(len)` turns the scalar length
   into a vector so the division is one operation.
5. Cross is the exception: it references specific lanes, so it cannot be
   written width-generic like the others.

```zig
const std = @import("std");

const Vec3 = @Vector(3, f32);

// Element-wise multiply, then a horizontal add. Works for any vector width,
// so `dot` is written once and reused by `length` below.
fn dot(a: Vec3, b: Vec3) f32 {
    return @reduce(.Add, a * b);
}

fn length(v: Vec3) f32 {
    return std.math.sqrt(dot(v, v));
}

// Divide every lane by the magnitude. `@splat` broadcasts the scalar length
// into a vector so the division is one SIMD op, not a loop.
fn normalize(v: Vec3) Vec3 {
    const len = length(v);
    if (len < 1e-6) return v; // a zero vector has no direction to keep
    const len_vec: Vec3 = @splat(len);
    return v / len_vec;
}

// Cross is the one operation that is genuinely 3D: it reads specific lanes,
// so it cannot be written width-generic like dot.
fn cross(a: Vec3, b: Vec3) Vec3 {
    return .{
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    };
}

fn printVec(out: anytype, v: Vec3) !void {
    try out.print("({d:.3}, {d:.3}, {d:.3})", .{ v[0], v[1], v[2] });
}

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    const a = Vec3{ 1.0, 0.0, 0.0 };
    const b = Vec3{ 0.5, 0.5, 0.0 };
    try out.print("dot     = {d:.3}\n", .{dot(a, b)});

    const v = Vec3{ 0.0, 3.0, 4.0 };
    try out.print("length  = {d:.3}\n", .{length(v)});

    const n = normalize(v);
    try out.writeAll("normal  = ");
    try printVec(out, n);
    try out.print(" (len {d:.3})\n", .{length(n)});

    // Right cross Up is Forward in a right-handed frame.
    const right = Vec3{ 1.0, 0.0, 0.0 };
    const up = Vec3{ 0.0, 1.0, 0.0 };
    try out.writeAll("cross   = ");
    try printVec(out, cross(right, up));
    try out.writeAll("\n");

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`06-cookbook.vector-algebra`)*

## `@reduce` collapses lanes to a scalar

`a * b` multiplies element-wise and stays a vector. To get a dot product you
still need the horizontal step: add lane 0 plus lane 1 plus lane 2 into one
number. That is `@reduce(.Add, product)`. The same builtin does `.Min`,
`.Max`, `.Mul`, and the bitwise reductions, so it is the general way to turn
a vector into a scalar. Because `dot` only uses `@reduce` and `*`, it works
for any width, and `length` gets it for free.

## `@splat` goes the other way

Normalization needs to divide every lane by one scalar, the length. You
cannot divide a vector by a scalar directly. `@splat(len)` broadcasts the
scalar into a vector whose lanes are all `len`, and then `v / len_vec` is a
single lane-wise division. The guard on a near-zero length matters: a zero
vector has no direction, and dividing by its length would produce `nan`
lanes that then poison every later computation silently.

## Cross is the odd one out

Dot, length, and normalize never care which lane is which, so they generalize
to any size. Cross does: it is defined only for 3D and each output lane reads
two specific input lanes. That is why it takes `@Vector(3, f32)` explicitly
and indexes with `a[1]`, `a[2]`, and so on. `Right × Up = Forward` in a
right-handed frame, which the snippet prints as `(0, 0, 1)`.

## Why the output is rounded

The result prints `normal = (0.000, 0.600, 0.800) (len 1.000)`. The length
reads as exactly one only because the output is rounded to three places.
`0.6` and `0.8` are not exactly representable in `f32`, so the true squared
sum is a hair above one and its square root a hair below. This is normal
float behavior, not a bug in the vector path. When you compare vector
lengths, compare against a tolerance rather than testing equality with `1.0`.

## Variations

- **Other widths:** the same `dot`, `length`, and `normalize` work on
  `@Vector(2, f32)` or `@Vector(4, f32)` unchanged; only `cross` is pinned
  to three lanes.
- **Doubles:** swap `f32` for `f64` when you need the precision and can spend
  the lanes.
- **Building on it:** reflection, projection, and lerp are all a dot, a
  `@splat`, and arithmetic away, so they follow the same shape.
- **Bulk arithmetic instead of geometry:**
  [the SIMD dot product recipe](https://www.ziglang.in/learn/how-to/simd-sum/) uses the same `@reduce`
  over long arrays, with a scalar tail, when the vectors are data rather
  than points in space.
