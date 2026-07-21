//! title: Pointer Sized Integers
//! `usize` and `isize` are as wide as a pointer on the target.

const std = @import("std");
const expect = std.testing.expect;

test "usize matches pointer width" {
    try expect(@sizeOf(usize) == @sizeOf(*u8));
    try expect(@sizeOf(isize) == @sizeOf(*u8));
}

test "usize is the index and length type" {
    // `.len` is a usize, and so is anything used to index a slice.
    const array = [_]u8{ 1, 2, 3 };
    const length: usize = array.len;
    try expect(length == 3);
    try expect(@TypeOf(array.len) == usize);
}

test "wasm32 is a 32-bit target" {
    // These snippets are compiled to wasm32-wasi, so a pointer is 4 bytes.
    // The same source on x86_64 would see 8.
    try expect(@sizeOf(usize) == 4);
}
