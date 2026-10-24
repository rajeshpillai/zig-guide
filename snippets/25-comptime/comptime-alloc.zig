//! title: A Runtime Allocator at Comptime
//! compile-fails
//! An `ArrayList` that grows during compilation, with a runtime allocator.

const std = @import("std");

const count = blk: {
    var list: std.ArrayList(u8) = .empty;
    list.append(std.heap.page_allocator, 1) catch unreachable;
    break :blk list.items.len;
};

pub fn main() void {
    std.debug.print("{d}\n", .{count});
}
