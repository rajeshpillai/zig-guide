//! title: Functions
//! Parameters are immutable; recursion needs care about stack depth.

const std = @import("std");
const expect = std.testing.expect;

fn addFive(x: u32) u32 {
    // Parameters are const. `x += 5` here would not compile.
    return x + 5;
}

fn fibonacci(n: u16) u16 {
    if (n == 0 or n == 1) return n;
    return fibonacci(n - 1) + fibonacci(n - 2);
}

test "calling a function" {
    const y = addFive(0);
    try expect(@TypeOf(y) == u32);
    try expect(y == 5);
}

test "recursion" {
    try expect(fibonacci(10) == 55);
}

test "values must be used" {
    // Zig has no unused-value warning because it is an error. `_ =` is the
    // explicit way to discard something.
    _ = addFive(1);
}
