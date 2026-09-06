# Floats

> IEEE-754 types and explicit conversions.

```zig
const std = @import("std");
const expect = std.testing.expect;

test "float widths" {
    const a: f16 = 1.5;
    const b: f32 = 1.5;
    const c: f64 = 1.5;
    try expect(a == 1.5 and b == 1.5 and c == 1.5);
    try expect(@sizeOf(f16) == 2 and @sizeOf(f64) == 8);
}

test "int and float do not mix implicitly" {
    const n: i32 = 3;
    const f: f32 = @floatFromInt(n);
    try expect(f == 3.0);

    // Truncates toward zero; checked in safety builds.
    const back: i32 = @intFromFloat(3.9);
    try expect(back == 3);
}

test "comptime_float is f128, not magic" {
    // Unlike comptime_int, which really is arbitrary precision,
    // comptime_float is backed by f128. Doing the arithmetic at compile
    // time buys you more bits, not exactness:
    const x = 0.1 + 0.2;
    try expect(x != 0.3);

    // The same sum in f64 is famously not 0.3 either.
    const y: f64 = 0.1;
    const z: f64 = 0.2;
    try expect(y + z != 0.3);

    // Compare with a tolerance instead of ==.
    try expect(std.math.approxEqAbs(f64, y + z, 0.3, 1e-12));
}

test "special values" {
    const inf = std.math.inf(f32);
    const nan = std.math.nan(f32);
    try expect(std.math.isInf(inf));
    try expect(std.math.isNan(nan));
    try expect(nan != nan); // NaN is not equal to itself
}
```

*Runnable: compiled to WebAssembly and executed by CI against Zig master. (`02-language.floats`)*

Zig has `f16`, `f32`, `f64`, `f80`, and `f128`. All are IEEE-754 (except
`f80`, the x87 extended format).

## No implicit int/float mixing

Neither direction happens on its own:

```zig
const f: f32 = @floatFromInt(n);
const n: i32 = @intFromFloat(f);   // truncates toward zero
```

This is deliberate. Implicit int-to-float conversion silently loses precision
for large integers, and float-to-int silently truncates; both are common
enough sources of bugs to be worth two extra words.

`@intFromFloat` truncates rather than rounds, and the result has to be
representable. Converting a value outside the target's range, or a NaN, is
illegal behaviour and is caught in a safety build. When the input is not
already known to be in range, clamp or check first: `std.math.lossyCast` does
the saturating version if that is what you want.

Between float types, `@floatCast` narrows and widening is implicit, since it
cannot lose anything.

## `comptime_float` is `f128`, not magic

This one trips people up, and it caught an earlier draft of this page. Unlike
`comptime_int`, which really is arbitrary precision, `comptime_float` is
backed by `f128`. Doing arithmetic at compile time gives you more bits, not
exact decimal:

```zig
const x = 0.1 + 0.2;
// x != 0.3, even at comptime
```

Floating point is still floating point. Compare with a tolerance:

```zig
std.math.approxEqAbs(f64, a, b, 1e-12)
```

`approxEqAbs` takes an absolute tolerance and is right when you know the
magnitude of the numbers. `approxEqRel` takes a relative one and is right when
you do not. An absolute tolerance of `1e-12` is impossibly strict for values
around a billion, and far too loose for values around `1e-15`.

## NaN and infinity

`std.math.nan(f32)` and `std.math.inf(f32)` construct them; `isNan` and
`isInf` test for them. Remember `nan != nan`. That is exactly why
`approxEqAbs` exists and why `==` on floats deserves suspicion.

NaN failing every comparison is the property that breaks things quietly. `a <
b` and `a >= b` are both false when either is NaN. So a sort with a NaN in it
does not merely put that value in an odd place. It breaks the ordering the
algorithm assumes. Filter NaNs out before sorting rather than hoping the
comparator copes.

Division by zero follows IEEE rather than trapping: `1.0 / 0.0` is infinity
and `0.0 / 0.0` is NaN. Integer division by zero is a different thing
entirely, and that one is illegal behaviour.

## Which width to use

`f64` unless you have a reason. `f32` halves the memory and is what graphics
and audio pipelines expect. It gives roughly seven decimal digits of
precision, which runs out faster than people expect once values are added up
in a loop. `f16` is for storage and for machine learning weights, not for
arithmetic. `f80` and `f128` exist for the cases that genuinely need them and
are software-emulated on most targets, so they are slow.

The precision question that actually matters is usually not the width. Money
in floats is wrong at any width, because 0.1 is not representable in binary at
all. Use an integer count of the smallest unit.
