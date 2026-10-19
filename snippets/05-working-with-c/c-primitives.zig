//! title: C Primitive Types
//! Types whose size follows the target's C ABI, not a fixed width.

const std = @import("std");
const expect = std.testing.expect;

test "c types are separate from fixed-width ones" {
    // `c_int` has the size of `int` on this target. Use `c_int` only at the
    // C boundary. In all other places, use i32, u64 and the other fixed types.
    try expect(@sizeOf(c_int) == 4);
    try expect(@sizeOf(c_char) == 1);
    try expect(c_int != i32); // different types, also at the same size
}

test "c_long varies by target" {
    // 4 bytes on wasm32 and Windows, 8 bytes on 64-bit Linux. The type
    // exists because of this difference. Thus do not hardcode i64.
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
