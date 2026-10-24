//! title: A New Tag Without a Handler
//! compile-fails
//! `Op` gets a `div` tag, and `Handlers` has no `div` function.

const std = @import("std");

const Op = enum { add, neg, div };

const Handlers = struct {
    pub fn add(a: i64, b: i64) i64 {
        return a + b;
    }
    pub fn neg(a: i64, _: i64) i64 {
        return -a;
    }
};

fn run(op: Op, a: i64, b: i64) i64 {
    return switch (op) {
        inline else => |tag| @field(Handlers, @tagName(tag))(a, b),
    };
}

pub fn main() void {
    std.debug.print("{d}\n", .{run(.add, 2, 3)});
}
