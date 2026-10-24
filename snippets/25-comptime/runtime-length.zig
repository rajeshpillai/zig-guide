//! title: A Runtime Value as an Array Length
//! compile-fails
//! The length of an array is part of its type. A `var` is not comptime-known.

const std = @import("std");

pub fn main() void {
    var n: usize = 4;
    _ = &n;
    // `n` never changes, but it is a `var`. Thus the compiler does not use
    // its value, and `[n]u8` is not a type that the compiler can make.
    const buf: [n]u8 = @splat(0);
    std.debug.print("{d}\n", .{buf.len});
}
