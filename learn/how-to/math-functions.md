# Recipe: The std.math Toolbox

> Constants, trig, powers, roots, rounding, and comparing floats safely.

## The problem

You need a formula: a sine, a square root, degrees turned into radians. The
functions are all in `std.math`, but a few details bite newcomers, chiefly
that trig works in radians and that `pow` wants its type up front. This is the
short reference.

## The plan

1. Read constants like `std.math.pi` straight from `std.math`.
2. Convert with `std.math.degreesToRadians`, then call `sin`, `cos`, `tan`.
3. Use `std.math.pow(T, base, exp)` and `std.math.sqrt`.
4. Round with `floor`, `ceil`, `round`, and reach for `hypot` and `clamp`.
5. Compare floats with `approxEqAbs`, never `==`.

```zig
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    // Constants live in std.math.
    try out.print("pi = {d:.5}\n", .{std.math.pi});

    // Trig takes radians. degreesToRadians converts for you.
    const deg: f32 = 90.0;
    const rad = std.math.degreesToRadians(deg);
    try out.print("{d:.1} deg = {d:.4} rad\n", .{ deg, rad });
    try out.print("sin(90 deg) = {d:.4}\n", .{std.math.sin(rad)});
    try out.print("cos(0)      = {d:.4}\n", .{std.math.cos(@as(f32, 0.0))});

    // pow is typed in its first argument; sqrt infers from its operand.
    try out.print("pow(2, 8)   = {d}\n", .{std.math.pow(f32, 2.0, 8.0)});
    try out.print("sqrt(64)    = {d}\n", .{std.math.sqrt(@as(f32, 64.0))});

    // Rounding and a couple of common helpers.
    try out.print("floor(2.7)  = {d}\n", .{std.math.floor(@as(f64, 2.7))});
    try out.print("ceil(2.1)   = {d}\n", .{std.math.ceil(@as(f64, 2.1))});
    try out.print("hypot(3, 4) = {d}\n", .{std.math.hypot(@as(f64, 3.0), 4.0)});

    // Never compare floats with ==; allow a tolerance. Why: see the floats chapter.
    try out.print("approxEqAbs(0.3, 0.30001, 1e-3)? {}\n", .{
        std.math.approxEqAbs(f64, 0.3, 0.30001, 1e-3),
    });

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`06-cookbook.math-functions`)*

## Trig is in radians

`std.math.sin`, `cos`, and `tan` take radians, like almost every language's
math library. `degreesToRadians` does the conversion, so `sin(degreesToRadians(90))`
is the readable way to get 1.0. The snippet prints `1.0000` rather than a bare
`1` only because of the `{d:.4}` format; the underlying `f32` result is a hair
under one, which the rounding hides. If you print it at full precision you will
see the epsilon.

## `pow` is typed, `sqrt` is not

`std.math.pow(f32, 2.0, 8.0)` takes the type as its first argument because it
has to pick an algorithm for that type. `std.math.sqrt` infers everything from
its operand, so `sqrt(@as(f32, 64.0))` is enough. Mixing the two signatures up
is the usual first compile error here.

## Comparing floats

The last line uses `std.math.approxEqAbs(f64, x, y, tolerance)`, which is how
you should test floats for equality. Plain `==` on floats is a trap: rounding
means values that are mathematically equal often differ in the last bits, and
values that look different can compare equal. There is a subtlety worth
knowing: whether `0.1 + 0.2 == 0.3` holds depends on the type and on when the
sum is computed. At `f32` it happens to be true; at `f64` computed at runtime
it is false; computed at compile time it may round back to true. That
inconsistency is exactly why you never lean on `==`. The
[floats chapter](https://www.ziglang.in/learn/language-basics/floats/) covers the representation behind
this.

## Variations

- **`approxEqRel`** scales the tolerance to the magnitude of the values, which
  is better when they can be large.
- **`clamp` and `hypot`** cover two common one-liners: bounding a value into a
  range, and a distance without an intermediate overflow.
- **Integer math** with overflow control is its own topic; see
  [checked math](https://www.ziglang.in/learn/how-to/checked-math/).
- **Vectors of numbers** rather than scalars are in
  [vector algebra](https://www.ziglang.in/learn/how-to/vector-algebra/).
