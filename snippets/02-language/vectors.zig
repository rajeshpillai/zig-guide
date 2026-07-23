//! title: Vectors
//! `@Vector(N, T)`: SIMD lanes with ordinary operators.

const std = @import("std");
const expect = std.testing.expect;

test "element-wise arithmetic" {
    const a: @Vector(4, i32) = .{ 1, 2, 3, 4 };
    const b: @Vector(4, i32) = .{ 10, 20, 30, 40 };
    const sum = a + b; // one operation across all lanes
    try expect(sum[0] == 11);
    try expect(sum[3] == 44);
}

test "reduce across lanes" {
    const v: @Vector(4, i32) = .{ 1, 2, 3, 4 };
    try expect(@reduce(.Add, v) == 10);
    try expect(@reduce(.Max, v) == 4);
}

test "splat fills every lane" {
    const v: @Vector(4, i32) = @splat(7);
    try expect(@reduce(.Add, v) == 28);
}

test "comparisons produce a vector of bools" {
    const a: @Vector(4, i32) = .{ 1, 5, 3, 7 };
    const b: @Vector(4, i32) = .{ 4, 4, 4, 4 };
    const mask = a > b; // @Vector(4, bool)
    try expect(@reduce(.Or, mask));
    try expect(!@reduce(.And, mask));

    // Select lane-wise between two vectors.
    const picked = @select(i32, mask, a, b);
    try expect(picked[0] == 4 and picked[1] == 5);
}

test "vectors and arrays convert" {
    const arr = [_]i32{ 1, 2, 3, 4 };
    const v: @Vector(4, i32) = arr;
    const back: [4]i32 = v;
    try expect(back[2] == 3);
}
