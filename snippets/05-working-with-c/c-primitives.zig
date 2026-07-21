//! title: C Primitive Types
//! Types whose size follows the target's C ABI, not a fixed width.

const std = @import("std");
const expect = std.testing.expect;

test "c types are separate from fixed-width ones" {
    // `c_int` is whatever `int` is on this target — use it only at the
    // C boundary, and use i32/u64/etc everywhere else.
    try expect(@sizeOf(c_int) == 4);
    try expect(@sizeOf(c_char) == 1);
    try expect(c_int != i32); // distinct types, even at the same size
}

test "c_long varies by target" {
    // 4 bytes on wasm32 and Windows, 8 on 64-bit Linux. This is exactly
    // why the type exists rather than hardcoding i64.
    try expect(@sizeOf(c_long) == 4); // wasm32
}

test "converting at the boundary" {
    const n: i32 = 42;
    const c: c_int = @intCast(n);
    try expect(c == 42);
}

test "the C ABI integer for pointers" {
    try expect(@sizeOf(usize) == @sizeOf(*anyopaque));
}
