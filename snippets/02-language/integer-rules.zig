//! title: Integer Rules
//! Arbitrary widths, no implicit narrowing, explicit overflow behaviour.

const std = @import("std");
const expect = std.testing.expect;

test "arbitrary bit widths" {
    // Any width from u0/i0 up to u65535 is a real type.
    const small: u3 = 7;
    try expect(@as(u8, small) == 7);
    try expect(std.math.maxInt(u3) == 7);
}

test "widening is implicit, narrowing is not" {
    const a: u8 = 200;
    const b: u16 = a; // always safe, so allowed
    try expect(b == 200);

    // `const c: u8 = b;` would not compile. Say what you mean:
    const c: u8 = @intCast(b); // checked in safety builds
    try expect(c == 200);
}

test "wrapping and saturating operators" {
    const max: u8 = 255;
    // Plain `max + 1` is illegal behaviour (a panic in safety builds).
    try expect(max +% 1 == 0); // wrapping
    try expect(max +| 1 == 255); // saturating
}

test "overflow can be detected instead" {
    const max: u8 = 255;
    const result = @addWithOverflow(max, 1);
    try expect(result[0] == 0); // wrapped value
    try expect(result[1] == 1); // overflow bit set
}

test "comptime_int has no width" {
    // Literals are arbitrary precision until they are given a type.
    const big = 1 << 100;
    try expect(big > 0);
    try expect(@TypeOf(1 + 1) == comptime_int);
}
