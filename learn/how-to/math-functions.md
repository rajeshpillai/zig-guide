# Recipe: The std.math Toolbox

> Constants, trig, powers, roots, rounding, and a safe comparison of floats.

The math functions of Zig are in `std.math`. Examples are `std.math.sqrt`, `std.math.sin` (which takes radians), `std.math.pow(T, base, exp)` and constants such as `std.math.pi`. Compare floats with `std.math.approxEqAbs`, not with `==`.

## The problem

You need a formula: a sine, a square root, or a change from degrees to radians. All of the functions are in `std.math`.

Two details cause most first mistakes. Trig functions use radians, and `pow` needs its type as the first argument. This chapter is the short reference.

## The plan

1. Read constants such as `std.math.pi` directly from `std.math`.
2. Convert with `std.math.degreesToRadians`. Then call `sin`, `cos` and `tan`.
3. Use `std.math.pow(T, base, exp)` and `std.math.sqrt`.
4. Round with `floor`, `ceil` and `round`. Use `hypot` and `clamp` when you need them.
5. Compare floats with `approxEqAbs`, never with `==`.

```zig
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    var buf: [1024]u8 = undefined;
    var file_writer = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const out = &file_writer.interface;

    // The constants are in std.math.
    try out.print("pi = {d:.5}\n", .{std.math.pi});

    // Trig functions take radians. degreesToRadians does the conversion.
    const deg: f32 = 90.0;
    const rad = std.math.degreesToRadians(deg);
    try out.print("{d:.1} deg = {d:.4} rad\n", .{ deg, rad });
    try out.print("sin(90 deg) = {d:.4}\n", .{std.math.sin(rad)});
    try out.print("cos(0)      = {d:.4}\n", .{std.math.cos(@as(f32, 0.0))});

    // pow takes the type as its first argument. sqrt gets the type from its operand.
    try out.print("pow(2, 8)   = {d}\n", .{std.math.pow(f32, 2.0, 8.0)});
    try out.print("sqrt(64)    = {d}\n", .{std.math.sqrt(@as(f32, 64.0))});

    // Rounding, and two common helpers.
    try out.print("floor(2.7)  = {d}\n", .{std.math.floor(@as(f64, 2.7))});
    try out.print("ceil(2.1)   = {d}\n", .{std.math.ceil(@as(f64, 2.1))});
    try out.print("hypot(3, 4) = {d}\n", .{std.math.hypot(@as(f64, 3.0), 4.0)});

    // Never compare floats with ==. Use a tolerance. The floats chapter tells why.
    try out.print("approxEqAbs(0.3, 0.30001, 1e-3)? {}\n", .{
        std.math.approxEqAbs(f64, 0.3, 0.30001, 1e-3),
    });

    try out.flush();
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`06-cookbook.math-functions`)*

## Trig uses radians

`std.math.sin`, `cos` and `tan` take radians, as the math library of almost each language does. `degreesToRadians` does the conversion. Thus `sin(degreesToRadians(90))` is the clear way to get 1.0.

The snippet prints `1.0000` and not `1` because of the `{d:.4}` format. At `f32`, the result is exactly one. Do not take that as a rule. For most angles of a whole number of degrees, the last bit of the `f32` sine is different from the correctly rounded value. For that reason, the comparison below uses a tolerance.

## `pow` takes a type, `sqrt` does not

`std.math.pow(f32, 2.0, 8.0)` takes the type as its first argument, because the function must select an algorithm for that type. `std.math.sqrt` gets all of the information from its operand. Thus `sqrt(@as(f32, 64.0))` is sufficient. The usual first compile error here comes from a confusion between the two signatures.

## Compare floats

The last line uses `std.math.approxEqAbs(f64, x, y, tolerance)`. Use this function to test floats for equality. A plain `==` on floats is not reliable.

Because of rounding, values that are mathematically equal often have different last bits. Also, values that look different can compare as equal.

The result of `0.1 + 0.2 == 0.3` depends on the type, and on when the program computes the sum:

- At `f32`, the result is true.
- At `f64`, computed at runtime, the result is false.
- At `f64`, computed at compile time, the rounding can make the result true.

Because the answer changes in this way, never use `==` for floats. The [floats chapter](https://www.ziglang.in/learn/language-basics/floats/) explains the representation that causes this.

## Variations

- **`approxEqRel`** scales the tolerance to the magnitude of the values. Use it when the values can be large.
- **`clamp` and `hypot`** do two common operations in one line. `clamp` keeps a value inside a range. `hypot` computes a distance without an overflow in the middle of the calculation.
- **Integer math** with overflow control is a different topic. See [checked math](https://www.ziglang.in/learn/how-to/checked-math/).
- **Vectors of numbers**, not scalars, are in [vector algebra](https://www.ziglang.in/learn/how-to/vector-algebra/).
