//! title: Floats
//! IEEE-754 types, and conversions that must be spelled out.

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
