//! title: Comptime
//! Run ordinary Zig at compile time; types are values there.

const std = @import("std");
const expect = std.testing.expect;

fn fibonacci(n: u32) u32 {
    if (n <= 1) return n;
    return fibonacci(n - 1) + fibonacci(n - 2);
}

// A generic function is just one that takes a `type` parameter.
fn List(comptime T: type) type {
    return struct {
        items: []T,

        pub fn first(self: @This()) ?T {
            return if (self.items.len == 0) null else self.items[0];
        }
    };
}

fn max(comptime T: type, a: T, b: T) T {
    return if (a > b) a else b;
}

test "evaluate at compile time" {
    // `comptime` forces evaluation during compilation; the binary contains
    // the answer, not the recursion.
    const small = comptime fibonacci(10);
    try expect(small == 55);
    try expect(@TypeOf(small) == u32);
}

test "the branch quota is a real limit" {
    // Comptime evaluation is capped at 1000 backwards branches so a runaway
    // computation fails the build instead of hanging the compiler.
    // fibonacci(20) blows past that; raise the ceiling deliberately.
    @setEvalBranchQuota(100_000);
    const result = comptime fibonacci(20);
    try expect(result == 6765);
}

test "types are comptime values" {
    const T = u16;
    const value: T = 300;
    try expect(@TypeOf(value) == u16);
}

test "generic data structure" {
    var backing = [_]i32{ 10, 20 };
    const list = List(i32){ .items = &backing };
    try expect(list.first().? == 10);

    // A different T produces a genuinely different type.
    try expect(List(i32) != List(u8));
}

test "generic function" {
    try expect(max(u8, 1, 2) == 2);
    try expect(max(f32, 1.5, 0.5) == 1.5);
}

test "comptime blocks can assert" {
    comptime {
        // A failed comptime assert is a compile error, not a test failure.
        std.debug.assert(@sizeOf(u32) == 4);
    }
}
