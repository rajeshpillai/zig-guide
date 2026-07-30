//! title: Printing with std.debug.print
//! norun
//! The shape older tutorials teach, kept compiled so CI fails if master drops it.

const std = @import("std");

// Two separate old habits in four lines: the parameterless `main`, and printing
// through `std.debug.print`. Both still work on current master, and they are
// independent of each other.
pub fn main() !void {
    std.debug.print("Hello, World!\n", .{});
}
