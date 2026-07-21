//! title: ABI
//! `extern` and `packed` give you layouts you can rely on.

const std = @import("std");
const expect = std.testing.expect;

// `extern struct` guarantees C layout: declaration order, C padding rules.
const CPoint = extern struct {
    x: i32,
    y: i32,
};

// `packed struct` is bit-level and backed by an integer, with no padding.
const Flags = packed struct {
    a: bool,
    b: bool,
    rest: u6,
};

// A plain struct may be reordered and padded however the compiler likes.
const Loose = struct {
    small: u8,
    big: u64,
};

test "extern struct follows C layout" {
    try expect(@sizeOf(CPoint) == 8);
    try expect(@offsetOf(CPoint, "x") == 0);
    try expect(@offsetOf(CPoint, "y") == 4);
}

test "packed struct is exactly its bits" {
    try expect(@bitSizeOf(Flags) == 8);
    try expect(@sizeOf(Flags) == 1);

    const f = Flags{ .a = true, .b = false, .rest = 0 };
    // Packed structs convert to their backing integer.
    try expect(@as(u8, @bitCast(f)) == 1);
}

test "plain structs make no layout promise" {
    // Zig is free to order these for packing, so do not assume offsets.
    try expect(@sizeOf(Loose) >= 9);
}

test "extern union and enum" {
    const E = extern union { i: i32, f: f32 };
    try expect(@sizeOf(E) == 4);

    // An enum with a C ABI tag type.
    const Colour = enum(c_int) { red, green, blue };
    try expect(@intFromEnum(Colour.green) == 1);
}

// `callconv(.c)` makes a Zig function callable from C.
export fn addFromC(a: c_int, b: c_int) callconv(.c) c_int {
    return a + b;
}

test "exported function is callable from Zig too" {
    try expect(addFromC(2, 3) == 5);
}
