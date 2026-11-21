# Recipe: Vector Algebra

> Dot, length, normalize and cross on @Vector, written as math and not as loops.

Vector math on the `@Vector(3, f32)` type of Zig uses the usual operators. The dot product is `@reduce(.Add, a * b)`, and normalization divides by `@splat(len)`. Only the cross product must use specific lanes by index.

## The problem

You do 3D work (graphics, physics, a game), and you need the four basic operations: dot product, length, normalization and cross product.

As scalar loops, these operations are hard to read, and it is easy to make small errors in them. With `@Vector`, the code looks like the math that it implements, and the compiler emits SIMD.

Errors usually occur in two steps:

- the change from a vector to one number
- the change from one number to a vector

## The plan

1. Select a vector type. `@Vector(3, f32)` has three `f32` lanes.
2. Dot product: multiply each lane by the same lane of the other vector, then add the lanes together.
3. Length is `sqrt(dot(v, v))`. It uses the dot function again.
4. Normalization divides each lane by the length, in one operation.
5. Cross is the exception. It uses specific lanes. Thus you cannot write it for all widths, as you can write the other operations.

```zig
const std = @import("std");

const Vec3 = @Vector(3, f32);

// Multiply element by element, then do a horizontal add. The body works for
// all vector widths. `length` below uses `dot` again.
fn dot(a: Vec3, b: Vec3) f32 {
    return @reduce(.Add, a * b);
}

fn length(v: Vec3) f32 {
    return std.math.sqrt(dot(v, v));
}

// Divide each lane by the magnitude. `@splat` copies the scalar length into
// a vector. Thus the division is one SIMD operation, not a loop.
fn normalize(v: Vec3) Vec3 {
    const len = length(v);
    if (len < 1e-6) return v; // a zero vector has no direction
    const len_vec: Vec3 = @splat(len);
    return v / len_vec;
}

// Cross is the only operation here that works only in 3D. It reads specific
// lanes. Thus you cannot write it for all widths, as you can write dot.
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

    // In a right-handed frame, Right cross Up is Forward.
    const right = Vec3{ 1.0, 0.0, 0.0 };
    const up = Vec3{ 0.0, 1.0, 0.0 };
    try out.writeAll("cross   = ");
    try printVec(out, cross(right, up));
    try out.writeAll("\n");

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`06-cookbook.vector-algebra`)*

## `@reduce` changes lanes to a scalar

`a * b` multiplies element by element, and the result is a vector. For a dot product, you also need the horizontal step: add lane 0, lane 1 and lane 2 into one number. That step is `@reduce(.Add, product)`.

The same builtin does `.Min`, `.Max`, `.Mul` and the bitwise reductions. Thus it is the general way to change a vector into a scalar.

The body of `dot` uses only `@reduce` and `*`. Thus the body works for all widths. `length` uses `dot`, thus it also works for all widths.

## `@splat` does the opposite

Normalization must divide each lane by one scalar, the length. You cannot divide a vector by a scalar directly.

`@splat(len)` copies the scalar into a vector with `len` in all lanes. Then `v / len_vec` is one division on all lanes.

The guard for a length near zero is necessary. A zero vector has no direction, and a division by its length gives `nan` lanes. These `nan` values then silently go into each later computation.

## Cross is different

Dot, length and normalize do not depend on the position of each lane. Thus they work for all sizes. Cross depends on the positions. Cross exists only for 3D, and each output lane reads two specific input lanes.

Thus `cross` takes `@Vector(3, f32)` explicitly, and it uses indexes such as `a[1]` and `a[2]`. In a right-handed frame, `Right × Up = Forward`. The snippet prints this result as `(0, 0, 1)`.

## The length is exactly one by chance

The result prints `normal = (0.000, 0.600, 0.800) (len 1.000)`. Here, the length is really exactly `1.0`, not a rounded `0.999`.

3, 4, 5 is a Pythagorean triple. `f32` cannot represent `0.6` and `0.8` exactly, but the sum of their squares is exactly one.

Other vectors can give a length that is not exact. If you normalize two thousand random vectors, about a third of the results are one or two bits from one. When you compare vector lengths, use a tolerance. Do not test for equality with `1.0`.

## Variations

- **Other widths:** the bodies of `dot`, `length` and `normalize` work without change on `@Vector(2, f32)` or `@Vector(4, f32)`. Only `cross` must have three lanes.
- **Doubles:** use `f64` in place of `f32` when you need the precision and can pay with fewer lanes.
- **More operations:** reflection, projection and lerp each need only a dot, a `@splat` and some arithmetic. Thus they use the same shape.
- **Arithmetic on large data, not geometry:** [the SIMD dot product recipe](https://www.ziglang.in/learn/how-to/simd-sum/) uses the same `@reduce` over long arrays, with a scalar tail. Use it when the vectors are data and not points in space.
