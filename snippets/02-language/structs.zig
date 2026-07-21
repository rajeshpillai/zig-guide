//! title: Structs
//! Data layout, default values, and methods.

const std = @import("std");
const expect = std.testing.expect;

const Vec3 = struct {
    x: f32 = 0, // default value
    y: f32 = 0,
    z: f32 = 0,

    pub fn dot(a: Vec3, b: Vec3) f32 {
        return a.x * b.x + a.y * b.y + a.z * b.z;
    }

    // Taking `*Vec3` lets the method mutate the receiver.
    pub fn scale(self: *Vec3, factor: f32) void {
        self.x *= factor;
        self.y *= factor;
        self.z *= factor;
    }
};

test "construct and read" {
    const v = Vec3{ .x = 1, .y = 2, .z = 3 };
    try expect(v.y == 2);
}

test "defaults fill in the rest" {
    const v = Vec3{ .x = 5 };
    try expect(v.y == 0 and v.z == 0);
}

test "methods" {
    const a = Vec3{ .x = 1, .y = 2, .z = 3 };
    const b = Vec3{ .x = 4, .y = 5, .z = 6 };
    try expect(Vec3.dot(a, b) == 32);
    try expect(a.dot(b) == 32); // same call, method syntax
}

test "mutating methods need a mutable receiver" {
    var v = Vec3{ .x = 1, .y = 1, .z = 1 };
    v.scale(3);
    try expect(v.x == 3);
}

test "field order is not guaranteed" {
    // Zig may reorder fields for packing unless you say otherwise with
    // `extern struct` (C ABI) or `packed struct` (bit-level layout).
    try expect(@sizeOf(Vec3) == 12);
}
