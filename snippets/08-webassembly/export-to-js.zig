//! title: Exporting Functions to a Host
//! `export fn` puts a function in the module's export table under its own name.
//! A host (JavaScript, wasmtime, another Zig program) calls it by that name.
//! The tests below verify the same functions this page's Run button executes.

const std = @import("std");

export fn add(a: i32, b: i32) i32 {
    return a + b;
}

export fn fib(n: u32) u64 {
    var a: u64 = 0;
    var b: u64 = 1;
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const next = a + b;
        a = b;
        b = next;
    }
    return a;
}

test add {
    try std.testing.expectEqual(@as(i32, 5), add(2, 3));
}

test fib {
    try std.testing.expectEqual(@as(u64, 55), fib(10));
}
